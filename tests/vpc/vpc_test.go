// vpc_test.go — Terratest integration test for the layered-reachability
// VPC module. Provisions the module against real AWS, asserts that the
// shape matches what the lab promises (private subnet, no IGW, three SSM
// endpoints, instance running), then destroys.
//
// Cost: ~$0.01 per run (t4g.nano for ~5 min plus three interface
// endpoints for the same window). Always tagged AutoDelete=<now+1h> so
// the janitor sweeps anything an aborted run leaves behind.

package vpc_test

import (
	"testing"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/service/ec2"
	terratestaws "github.com/gruntwork-io/terratest/modules/aws"
	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/gillzj00/networking-fun/tests/helpers"
)

const expectedVpcCidr = "10.20.0.0/24"
const expectedSubnetCidr = "10.20.0.0/27"

func TestLayeredReachabilityVPC(t *testing.T) {
	t.Parallel()

	run := helpers.NewRun(t)
	opts := run.TerraformOptions(t, "fixtures", nil)

	defer helpers.EnsureDestroy(t, opts)

	terraform.InitAndApply(t, opts)

	vpcID := terraform.Output(t, opts, "vpc_id")
	subnetID := terraform.Output(t, opts, "private_subnet_id")
	instanceID := terraform.Output(t, opts, "instance_id")
	flowLogGroup := terraform.Output(t, opts, "flow_log_group_name")
	endpointMap := terraform.OutputMap(t, opts, "ssm_endpoint_ids")

	require.NotEmpty(t, vpcID)
	require.NotEmpty(t, subnetID)
	require.NotEmpty(t, instanceID)
	require.NotEmpty(t, flowLogGroup)

	client := terratestaws.NewEc2Client(t, run.Region)

	// --- VPC shape ---
	vpcOut, err := client.DescribeVpcs(&ec2.DescribeVpcsInput{
		VpcIds: aws.StringSlice([]string{vpcID}),
	})
	require.NoError(t, err)
	require.Len(t, vpcOut.Vpcs, 1)
	assert.Equal(t, expectedVpcCidr, aws.StringValue(vpcOut.Vpcs[0].CidrBlock))
	assert.True(t, vpcAttribute(t, client, vpcID, "enableDnsSupport"),
		"happy-path lab VPC must have DNS support enabled")
	assert.True(t, vpcAttribute(t, client, vpcID, "enableDnsHostnames"),
		"happy-path lab VPC must have DNS hostnames enabled")

	// --- Subnet ---
	subnetOut, err := client.DescribeSubnets(&ec2.DescribeSubnetsInput{
		SubnetIds: aws.StringSlice([]string{subnetID}),
	})
	require.NoError(t, err)
	require.Len(t, subnetOut.Subnets, 1)
	assert.Equal(t, expectedSubnetCidr, aws.StringValue(subnetOut.Subnets[0].CidrBlock))
	assert.Equal(t, vpcID, aws.StringValue(subnetOut.Subnets[0].VpcId))
	assert.False(t, aws.BoolValue(subnetOut.Subnets[0].MapPublicIpOnLaunch),
		"private subnet must not auto-assign public IPs")

	// --- Route table: no IGW route ---
	rtOut, err := client.DescribeRouteTables(&ec2.DescribeRouteTablesInput{
		Filters: []*ec2.Filter{{
			Name:   aws.String("association.subnet-id"),
			Values: aws.StringSlice([]string{subnetID}),
		}},
	})
	require.NoError(t, err)
	require.Len(t, rtOut.RouteTables, 1, "subnet must be associated with exactly one route table")
	for _, route := range rtOut.RouteTables[0].Routes {
		// Every route table has an implicit "local" route for the VPC CIDR;
		// AWS reports it with GatewayId="local". Skip it — we only care that
		// the user hasn't added an IGW/NAT route.
		if aws.StringValue(route.GatewayId) == "local" {
			continue
		}
		assert.Nil(t, route.GatewayId, "private subnet must not route to an IGW")
		assert.Nil(t, route.NatGatewayId, "private subnet must not route to a NAT gateway")
	}

	// --- No IGW attached to the VPC at all ---
	igwOut, err := client.DescribeInternetGateways(&ec2.DescribeInternetGatewaysInput{
		Filters: []*ec2.Filter{{
			Name:   aws.String("attachment.vpc-id"),
			Values: aws.StringSlice([]string{vpcID}),
		}},
	})
	require.NoError(t, err)
	assert.Empty(t, igwOut.InternetGateways, "lab VPC must not have an IGW")

	// --- SSM family of VPC endpoints ---
	assert.Len(t, endpointMap, 3, "expected ssm, ssmmessages, ec2messages endpoints")
	for _, key := range []string{"ssm", "ssmmessages", "ec2messages"} {
		assert.Contains(t, endpointMap, key, "missing %s endpoint", key)
	}

	// --- Instance is running, in the right subnet, no public IP ---
	instOut, err := client.DescribeInstances(&ec2.DescribeInstancesInput{
		InstanceIds: aws.StringSlice([]string{instanceID}),
	})
	require.NoError(t, err)
	require.Len(t, instOut.Reservations, 1)
	require.Len(t, instOut.Reservations[0].Instances, 1)
	inst := instOut.Reservations[0].Instances[0]
	assert.Equal(t, subnetID, aws.StringValue(inst.SubnetId))
	assert.Empty(t, aws.StringValue(inst.PublicIpAddress), "instance must not have a public IP")
	assert.Equal(t, ec2.InstanceStateNameRunning, aws.StringValue(inst.State.Name))
}

// vpcAttribute reads a boolean VPC attribute. DescribeVpcs doesn't surface
// EnableDnsSupport / EnableDnsHostnames inline.
func vpcAttribute(t *testing.T, client *ec2.EC2, vpcID, attr string) bool {
	t.Helper()
	out, err := client.DescribeVpcAttribute(&ec2.DescribeVpcAttributeInput{
		VpcId:     aws.String(vpcID),
		Attribute: aws.String(attr),
	})
	require.NoError(t, err)
	switch attr {
	case "enableDnsSupport":
		return aws.BoolValue(out.EnableDnsSupport.Value)
	case "enableDnsHostnames":
		return aws.BoolValue(out.EnableDnsHostnames.Value)
	default:
		t.Fatalf("unsupported VPC attribute: %s", attr)
		return false
	}
}
