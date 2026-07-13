"""Brute-force delete leftover lab VPCs and their dependencies.

Invoked by the lab-nuke-vpcs workflow when terratest leaks VPCs faster
than the scanner-only janitor can mop them up. Every targeted VPC must
carry ManagedBy=terratest so we cannot accidentally take out shared
networking like the default VPC or platform-owned baselines.
"""

import os
import sys
import time

import boto3
from botocore.exceptions import ClientError


REGION = os.environ.get("AWS_REGION", "us-east-2")

session = boto3.Session(region_name=REGION)
ec2 = session.client("ec2")
lam = session.client("lambda")
logs = session.client("logs")


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def safe(fn, *a, **kw):
    try:
        return fn(*a, **kw)
    except ClientError as e:
        code = e.response["Error"].get("Code", "?")
        msg = e.response["Error"].get("Message", "")[:160]
        log(f"  ! {fn.__name__}: {code} {msg}")
        return None


def assert_managed_by_terratest(vpc):
    """Refuse to touch a VPC that isn't tagged ManagedBy=terratest."""
    resp = ec2.describe_vpcs(VpcIds=[vpc])
    vpcs = resp.get("Vpcs", [])
    if not vpcs:
        raise RuntimeError(f"{vpc}: not found")
    tags = {t["Key"]: t["Value"] for t in vpcs[0].get("Tags") or []}
    if tags.get("ManagedBy") != "terratest":
        raise RuntimeError(
            f"{vpc}: missing ManagedBy=terratest tag (got {tags.get('ManagedBy')!r}); refusing"
        )


def delete_lambdas_in_vpc(vpc):
    funcs = lam.list_functions()["Functions"]
    for f in funcs:
        if (f.get("VpcConfig") or {}).get("VpcId") == vpc:
            log(f"  delete lambda {f['FunctionName']}")
            safe(lam.delete_function, FunctionName=f["FunctionName"])
            safe(logs.delete_log_group, logGroupName=f"/aws/lambda/{f['FunctionName']}")


def terminate_instances(vpc):
    res = ec2.describe_instances(Filters=[{"Name": "vpc-id", "Values": [vpc]}])
    ids = [
        i["InstanceId"]
        for r in res["Reservations"]
        for i in r["Instances"]
        if i["State"]["Name"] != "terminated"
    ]
    if not ids:
        return
    log(f"  terminate {ids}")
    safe(ec2.terminate_instances, InstanceIds=ids)
    log("  wait for terminated...")
    try:
        ec2.get_waiter("instance_terminated").wait(
            InstanceIds=ids, WaiterConfig={"Delay": 10, "MaxAttempts": 60}
        )
    except Exception as e:
        log(f"  ! waiter: {e}")


def delete_nat_gateways(vpc):
    for ngw in ec2.describe_nat_gateways(Filters=[{"Name": "vpc-id", "Values": [vpc]}])["NatGateways"]:
        if ngw["State"] in ("deleted", "deleting"):
            continue
        log(f"  delete ngw {ngw['NatGatewayId']}")
        safe(ec2.delete_nat_gateway, NatGatewayId=ngw["NatGatewayId"])


def wait_for_nat_deleted(vpc):
    while True:
        gws = [
            g
            for g in ec2.describe_nat_gateways(Filters=[{"Name": "vpc-id", "Values": [vpc]}])["NatGateways"]
            if g["State"] != "deleted"
        ]
        if not gws:
            return
        log(f"  waiting for {len(gws)} NAT GW(s)...")
        time.sleep(15)


def delete_endpoints(vpc):
    eps = ec2.describe_vpc_endpoints(Filters=[{"Name": "vpc-id", "Values": [vpc]}])["VpcEndpoints"]
    ids = [e["VpcEndpointId"] for e in eps]
    if ids:
        log(f"  delete endpoints {ids}")
        safe(ec2.delete_vpc_endpoints, VpcEndpointIds=ids)


def delete_enis(vpc):
    for eni in ec2.describe_network_interfaces(Filters=[{"Name": "vpc-id", "Values": [vpc]}])["NetworkInterfaces"]:
        if eni.get("Attachment"):
            log(f"  detach eni {eni['NetworkInterfaceId']}")
            safe(
                ec2.detach_network_interface,
                AttachmentId=eni["Attachment"]["AttachmentId"],
                Force=True,
            )
            time.sleep(2)
        log(f"  delete eni {eni['NetworkInterfaceId']}")
        safe(ec2.delete_network_interface, NetworkInterfaceId=eni["NetworkInterfaceId"])


def detach_and_delete_igws(vpc):
    for igw in ec2.describe_internet_gateways(
        Filters=[{"Name": "attachment.vpc-id", "Values": [vpc]}]
    )["InternetGateways"]:
        log(f"  detach+delete igw {igw['InternetGatewayId']}")
        safe(ec2.detach_internet_gateway, InternetGatewayId=igw["InternetGatewayId"], VpcId=vpc)
        safe(ec2.delete_internet_gateway, InternetGatewayId=igw["InternetGatewayId"])


def delete_subnets(vpc):
    for s in ec2.describe_subnets(Filters=[{"Name": "vpc-id", "Values": [vpc]}])["Subnets"]:
        log(f"  delete subnet {s['SubnetId']}")
        safe(ec2.delete_subnet, SubnetId=s["SubnetId"])


def delete_security_groups(vpc):
    sgs = [
        s
        for s in ec2.describe_security_groups(Filters=[{"Name": "vpc-id", "Values": [vpc]}])["SecurityGroups"]
        if s["GroupName"] != "default"
    ]
    for sg in sgs:
        if sg.get("IpPermissions"):
            safe(ec2.revoke_security_group_ingress, GroupId=sg["GroupId"], IpPermissions=sg["IpPermissions"])
        if sg.get("IpPermissionsEgress"):
            safe(ec2.revoke_security_group_egress, GroupId=sg["GroupId"], IpPermissions=sg["IpPermissionsEgress"])
    for sg in sgs:
        log(f"  delete sg {sg['GroupId']}")
        safe(ec2.delete_security_group, GroupId=sg["GroupId"])


def delete_route_tables(vpc):
    for rt in ec2.describe_route_tables(Filters=[{"Name": "vpc-id", "Values": [vpc]}])["RouteTables"]:
        for a in rt.get("Associations", []):
            if not a.get("Main"):
                safe(ec2.disassociate_route_table, AssociationId=a["RouteTableAssociationId"])
        if any(a.get("Main") for a in rt.get("Associations", [])):
            continue
        log(f"  delete route table {rt['RouteTableId']}")
        safe(ec2.delete_route_table, RouteTableId=rt["RouteTableId"])


def delete_nacls(vpc):
    for n in ec2.describe_network_acls(Filters=[{"Name": "vpc-id", "Values": [vpc]}])["NetworkAcls"]:
        if n.get("IsDefault"):
            continue
        log(f"  delete nacl {n['NetworkAclId']}")
        safe(ec2.delete_network_acl, NetworkAclId=n["NetworkAclId"])


def nuke(vpc):
    log(f"=== nuking {vpc} ===")
    assert_managed_by_terratest(vpc)
    delete_lambdas_in_vpc(vpc)
    terminate_instances(vpc)
    delete_nat_gateways(vpc)
    wait_for_nat_deleted(vpc)
    delete_endpoints(vpc)
    # ENIs sometimes need a beat after NAT/lambda removal.
    for _ in range(6):
        delete_enis(vpc)
        leftover = ec2.describe_network_interfaces(Filters=[{"Name": "vpc-id", "Values": [vpc]}])["NetworkInterfaces"]
        if not leftover:
            break
        log(f"  {len(leftover)} ENIs remain, waiting 15s...")
        time.sleep(15)
    detach_and_delete_igws(vpc)
    delete_subnets(vpc)
    delete_security_groups(vpc)
    delete_route_tables(vpc)
    delete_nacls(vpc)
    log(f"  delete vpc {vpc}")
    res = safe(ec2.delete_vpc, VpcId=vpc)
    if res is None:
        raise RuntimeError(f"{vpc}: delete_vpc failed")
    log(f"  OK {vpc}")


def main():
    vpcs = sys.argv[1:]
    if not vpcs:
        print("usage: nuke_vpcs.py <vpc-id> [<vpc-id> ...]", file=sys.stderr)
        sys.exit(2)
    failures = []
    for v in vpcs:
        try:
            nuke(v)
        except Exception as e:
            log(f"  EXCEPTION while nuking {v}: {type(e).__name__}: {e}")
            failures.append(v)
    if failures:
        log(f"FAILED: {failures}")
        sys.exit(1)


if __name__ == "__main__":
    main()
