// lab1_test.go — end-to-end Terratest for the layered-reachability lab.
// Each test applies labs/modules/layered-reachability/ + probe, invokes
// the probe Lambda, asserts the probe matrix matches the per-scenario
// expectation, then destroys.
//
// Cost: ~$0.02 per test (t4g.nano + three interface endpoints + Lambda
// for ~10 min). Resources carry AutoDelete=<now+1h> so the janitor
// sweeps anything an aborted run leaves behind.

package lab1_test

import (
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/service/ssm"
	terratestaws "github.com/gruntwork-io/terratest/modules/aws"
	"github.com/gruntwork-io/terratest/modules/retry"
	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/gillzj00/networking-fun/tests/helpers"
)

// probeResult mirrors the shape returned by labs/modules/probe/src/handler.py.
// Only the fields the assertions read are decoded; the renderer-only fields
// (description, detail, duration_ms) are ignored.
type probeResult struct {
	Name               string `json:"name"`
	Source             string `json:"source"`
	Destination        string `json:"destination"`
	Passed             bool   `json:"passed"`
	Expected           bool   `json:"expected"`
	MatchedExpectation bool   `json:"matched_expectation"`
}

type probeSummary struct {
	Lab                string        `json:"lab"`
	Scenario           string        `json:"scenario"`
	AllPassed          bool          `json:"all_passed"`
	MatchedExpectation bool          `json:"matched_expectation"`
	Results            []probeResult `json:"results"`
}

func TestLab1HappyPath(t *testing.T) {
	t.Parallel()

	results := provisionAndProbe(t, "happy-path")

	// happy-path expects every probe to pass.
	require.Equal(t, 4, len(results.Results), "layered-reachability probe should run 4 checks")
	for _, r := range results.Results {
		assert.True(t, r.Passed, "happy-path probe %q should pass; got fail", r.Name)
		assert.True(t, r.Expected, "happy-path probe %q expected=true", r.Name)
		assert.True(t, r.MatchedExpectation, "happy-path probe %q must match expectation", r.Name)
	}
	assert.True(t, results.AllPassed, "happy-path summary all_passed must be true")
	assert.True(t, results.MatchedExpectation, "happy-path summary matched_expectation must be true")
}

func TestLab1NaclDenyEgress(t *testing.T) {
	t.Parallel()

	results := provisionAndProbe(t, "nacl-deny-egress")

	// nacl-deny-egress: DNS checks pass (intra-subnet resolver) but the
	// SSM API and instance-registration checks fail because the NACL
	// drops outbound TCP/443 from the subnet. matched_expectation must
	// hold across every row.
	byName := map[string]probeResult{}
	for _, r := range results.Results {
		byName[r.Name] = r
	}

	require.Len(t, byName, 4, "expected 4 probes")
	assertProbe(t, byName, "dns_ssm_endpoint", true)
	assertProbe(t, byName, "dns_public_hostname", true)
	assertProbe(t, byName, "ssm_api_reachable", false)
	assertProbe(t, byName, "instance_registered_with_ssm", false)

	assert.True(t, results.MatchedExpectation, "fault scenario must match expectation matrix")
	// all_passed is False by design for fault scenarios.
	assert.False(t, results.AllPassed, "fault scenario should not have all_passed=true")
}

func TestLab1MissingVpcEndpoint(t *testing.T) {
	t.Parallel()

	results := provisionAndProbe(t, "missing-vpc-endpoint")

	// missing-vpc-endpoint: the ssm interface endpoint is absent, so the
	// resolver still answers (DNS is on, ssm.<region>.amazonaws.com falls
	// back to the public address), but TCP/443 to a non-VPC destination
	// has no route. SSM API and registration both fail.
	byName := map[string]probeResult{}
	for _, r := range results.Results {
		byName[r.Name] = r
	}

	require.Len(t, byName, 4, "expected 4 probes")
	assertProbe(t, byName, "dns_ssm_endpoint", true)
	assertProbe(t, byName, "dns_public_hostname", true)
	assertProbe(t, byName, "ssm_api_reachable", false)
	assertProbe(t, byName, "instance_registered_with_ssm", false)

	assert.True(t, results.MatchedExpectation, "fault scenario must match expectation matrix")
	assert.False(t, results.AllPassed, "fault scenario should not have all_passed=true")
}

func TestLab1DnsDisabled(t *testing.T) {
	t.Parallel()

	results := provisionAndProbe(t, "dns-disabled")

	// dns-disabled: VPC DNS support is off. The Amazon-provided resolver
	// returns nothing, so every probe that has to resolve a hostname
	// fails — endpoint lookup, public hostname, SSM API, registration.
	byName := map[string]probeResult{}
	for _, r := range results.Results {
		byName[r.Name] = r
	}

	require.Len(t, byName, 4, "expected 4 probes")
	assertProbe(t, byName, "dns_ssm_endpoint", false)
	assertProbe(t, byName, "dns_public_hostname", false)
	assertProbe(t, byName, "ssm_api_reachable", false)
	assertProbe(t, byName, "instance_registered_with_ssm", false)

	assert.True(t, results.MatchedExpectation, "fault scenario must match expectation matrix")
	assert.False(t, results.AllPassed, "fault scenario should not have all_passed=true")
}

// provisionAndProbe is the common lifecycle for every lab1 test: apply
// the fixture for the given scenario, invoke the probe, return the
// parsed summary. Destroy is deferred regardless of outcome.
func provisionAndProbe(t *testing.T, scenario string) probeSummary {
	t.Helper()

	run := helpers.NewRun(t)
	opts := run.TerraformOptions(t, "fixtures", map[string]interface{}{
		"scenario": scenario,
	})

	defer helpers.EnsureDestroy(t, opts)

	terraform.InitAndApply(t, opts)

	functionName := terraform.Output(t, opts, "probe_function_name")
	require.NotEmpty(t, functionName, "probe_function_name output must be set")

	// SSM agent registration takes ~90 s on happy-path. Fault scenarios
	// deliberately fail to register, but the probe call itself still
	// needs to wait long enough that registration *would* have happened
	// on the baseline — otherwise a happy-path test could race the agent.
	if scenario == "happy-path" {
		waitForSsmRegistration(t, run.Region, terraform.Output(t, opts, "instance_id"))
	} else {
		time.Sleep(90 * time.Second)
	}

	payload := invokeProbe(t, run.Region, functionName)
	var summary probeSummary
	require.NoError(t, json.Unmarshal(payload, &summary), "probe payload must decode as JSON")

	assert.Equal(t, "layered-reachability", summary.Lab)
	assert.Equal(t, scenario, summary.Scenario)

	return summary
}

func assertProbe(t *testing.T, byName map[string]probeResult, name string, expected bool) {
	t.Helper()
	r, ok := byName[name]
	require.True(t, ok, "probe %q missing from results", name)
	assert.Equal(t, expected, r.Passed, "probe %q passed=%v want %v", name, r.Passed, expected)
	assert.Equal(t, expected, r.Expected, "probe %q expected column should be %v", name, expected)
	assert.True(t, r.MatchedExpectation, "probe %q must match expectation", name)
}

func invokeProbe(t *testing.T, region, functionName string) []byte {
	t.Helper()
	return terratestaws.InvokeFunction(t, region, functionName, nil)
}

// waitForSsmRegistration polls ssm:DescribeInstanceInformation until the
// instance reports PingStatus=Online. happy-path tests depend on this
// because the probe's instance_registered_with_ssm check races the
// agent's first poll. If the wait gives up we still proceed — the probe
// will report whatever state the agent is in and the assertions fail
// with a useful payload.
func waitForSsmRegistration(t *testing.T, region, instanceID string) {
	t.Helper()
	const maxAttempts = 30
	const sleepBetween = 10 * time.Second

	client := terratestaws.NewSsmClient(t, region)

	_, err := retry.DoWithRetryE(t, "wait for SSM registration", maxAttempts, sleepBetween, func() (string, error) {
		out, describeErr := client.DescribeInstanceInformation(&ssm.DescribeInstanceInformationInput{
			Filters: []*ssm.InstanceInformationStringFilter{{
				Key:    aws.String("InstanceIds"),
				Values: []*string{aws.String(instanceID)},
			}},
		})
		if describeErr != nil {
			return "", describeErr
		}
		for _, info := range out.InstanceInformationList {
			if info.InstanceId != nil && *info.InstanceId == instanceID &&
				info.PingStatus != nil && *info.PingStatus == "Online" {
				return "online", nil
			}
		}
		return "", fmt.Errorf("instance %s not yet Online in SSM", instanceID)
	})
	if err != nil {
		t.Logf("SSM registration wait gave up; probe will report the agent state regardless: %v", err)
	}
}
