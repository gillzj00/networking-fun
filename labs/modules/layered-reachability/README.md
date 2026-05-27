# Lab #1 — `layered-reachability`

Private-only VPC, one `t4g.nano` Amazon Linux 2023 (arm64) EC2 instance,
SSM-attached through three VPC interface endpoints (`ssm`, `ssmmessages`,
`ec2messages`). No IGW, no NAT. VPC Flow Logs to CloudWatch (1-day retention).

**Lesson:** you don't need internet egress to manage instances if you have the
right combination of DNS, endpoints, SGs, and NACLs.

## Probe matrix

Four checks run for every scenario; the `expected` value flips per scenario. A
fault scenario "passes" when each check matches its expectation.

| check | what it tests |
|---|---|
| `dns_ssm_endpoint` | VPC DNS resolves the regional SSM endpoint. |
| `dns_public_hostname` | VPC DNS resolves a public hostname. |
| `ssm_api_reachable` | Probe Lambda can call `ssm:DescribeInstanceInformation` through the endpoint. |
| `instance_registered_with_ssm` | Lab instance is `PingStatus=Online`. |

## Scenarios

### `happy-path`

Baseline: every layer works. The instance registers with SSM within ~90s and
all four probes pass.

| check | expected |
|---|---|
| `dns_ssm_endpoint` | pass |
| `dns_public_hostname` | pass |
| `ssm_api_reachable` | pass |
| `instance_registered_with_ssm` | pass |

### `nacl-deny-egress`

Custom NACL on the private subnet allows everything inbound, denies everything
outbound. SGs (stateful) still authorize egress; NACLs (stateless) drop every
outbound packet regardless. The VPC DNS resolver is intra-subnet so name
resolution still works, but anything leaving the subnet on TCP/443 fails.

**Lesson:** an SG that authorizes a session doesn't matter if a NACL drops the
matching outbound or return packet.

| check | expected | why |
|---|---|---|
| `dns_ssm_endpoint` | pass | VPC resolver is intra-subnet |
| `dns_public_hostname` | pass | same |
| `ssm_api_reachable` | fail | TCP/443 dropped at subnet boundary |
| `instance_registered_with_ssm` | fail | SSM agent can't reach the control plane |

### `missing-vpc-endpoint`

Drops the `ssm` interface endpoint; `ssmmessages` and `ec2messages` stay so the
failure is pinned to a single missing piece. The regional SSM hostname falls
through to public DNS and resolves to a public IP, but the private subnet has
no route there.

**Lesson:** SSM needs all three of the `ssm`/`ssmmessages`/`ec2messages`
endpoints in a no-internet VPC. DNS resolving is not the same as reachability.

| check | expected | why |
|---|---|---|
| `dns_ssm_endpoint` | pass | public DNS returns the public service IP |
| `dns_public_hostname` | pass | same |
| `ssm_api_reachable` | fail | no route from private subnet to public IP |
| `instance_registered_with_ssm` | fail | agent can't reach the control plane |

### `dns-disabled`

`enable_dns_support` and `enable_dns_hostnames` both off on the VPC. The
endpoints stay but `private_dns_enabled` flips off because that feature
requires VPC DNS. The Amazon-provided resolver returns nothing.

**Lesson:** VPC DNS is a per-VPC toggle that quietly breaks both name
resolution and the private-DNS overlay that lets interface endpoints stand in
for public service hostnames.

| check | expected | why |
|---|---|---|
| `dns_ssm_endpoint` | fail | VPC resolver returns nothing |
| `dns_public_hostname` | fail | same |
| `ssm_api_reachable` | fail | boto3 can't resolve the endpoint hostname |
| `instance_registered_with_ssm` | fail | same |
