// lab2_test.go — end-to-end Terratest for the three-tier-segmentation
// lab. Each test applies labs/modules/three-tier-segmentation/ + probe,
// invokes the probe Lambda (which fans out via SSM RunCommand to every
// tier instance), asserts the 3×3 connectivity matrix matches the
// per-scenario expectation, then destroys.
//
// Cost: ~$0.03 per test (three t4g.nano instances + three interface
// endpoints + Lambda for ~10 min). Resources carry AutoDelete=<now+1h>.

package lab2_test

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

type probeResult struct {
	Name               string `json:"name"`
	Source             string `json:"source"`
	Destination        string `json:"destination"`
	Port               *int   `json:"port"`
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

// Expected matrices mirror THREE_TIER_EXPECTED in
// labs/modules/probe/src/handler.py. The Go test re-asserts them
// independently so a regression in the probe handler — say, a default
// that silently flips a cell — fails this test, not just the live PR
// probe matrix.
var happyPathMatrix = map[string]map[string]bool{
	"web": {"app": true, "db": false},
	"app": {"web": true, "db": true},
	"db":  {"web": true, "app": false},
}

var naclStatelessReturnMatrix = map[string]map[string]bool{
	"web": {"app": true, "db": false},
	"app": {"web": true, "db": false},
	"db":  {"web": true, "app": false},
}

func TestLab2HappyPath(t *testing.T) {
	t.Parallel()

	results := provisionAndProbe(t, "happy-path")
	require.Equal(t, 6, len(results.Results), "three-tier probe should run 3*2=6 pair checks")

	assertMatrix(t, results.Results, happyPathMatrix)
	assert.True(t, results.MatchedExpectation, "happy-path matrix must match expectation")
}

func TestLab2NaclStatelessReturn(t *testing.T) {
	t.Parallel()

	results := provisionAndProbe(t, "nacl-stateless-return")
	require.Equal(t, 6, len(results.Results), "three-tier probe should run 3*2=6 pair checks")

	assertMatrix(t, results.Results, naclStatelessReturnMatrix)

	// Spot-check the key cell: app->db is the SG-allowed path that the
	// stateless NACL drops on the return SYN-ACK. The whole lesson of
	// this scenario lives in this single cell.
	appToDb := findPair(t, results.Results, "app", "db")
	assert.False(t, appToDb.Passed, "app->db must fail when the db subnet's stateless NACL drops the return packet")
	assert.False(t, appToDb.Expected, "app->db expected column must read fail for nacl-stateless-return")
	assert.True(t, appToDb.MatchedExpectation, "app->db must match expectation")

	assert.True(t, results.MatchedExpectation, "fault scenario matrix must match expectation")
	assert.False(t, results.AllPassed, "fault scenario should not be all_passed=true")
}

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

	instanceIDs := terraform.OutputMap(t, opts, "instance_ids")
	require.Len(t, instanceIDs, 3, "three-tier lab must expose three tier instance IDs")
	for _, tier := range []string{"web", "app", "db"} {
		require.NotEmpty(t, instanceIDs[tier], "tier %s instance ID missing from output", tier)
	}

	// Every tier instance must be Online before the probe runs, because
	// the probe fans out via SSM RunCommand to each one. None of the
	// scenarios here break SSM reachability for the tier instances
	// (the NACL in nacl-stateless-return is on the db subnet's
	// per-port egress, which still allows TCP/443 to the endpoint SG).
	waitForAllOnline(t, run.Region, instanceIDs)

	payload := invokeProbe(t, run.Region, functionName)
	var summary probeSummary
	require.NoError(t, json.Unmarshal(payload, &summary), "probe payload must decode as JSON")

	assert.Equal(t, "three-tier-segmentation", summary.Lab)
	assert.Equal(t, scenario, summary.Scenario)

	return summary
}

func assertMatrix(t *testing.T, results []probeResult, expected map[string]map[string]bool) {
	t.Helper()
	got := map[string]map[string]probeResult{}
	for _, r := range results {
		if got[r.Source] == nil {
			got[r.Source] = map[string]probeResult{}
		}
		got[r.Source][r.Destination] = r
	}
	for source, dests := range expected {
		for dest, wantPass := range dests {
			r, ok := got[source][dest]
			require.True(t, ok, "probe missing for %s -> %s", source, dest)
			assert.Equal(t, wantPass, r.Passed, "%s -> %s passed=%v want %v", source, dest, r.Passed, wantPass)
			assert.Equal(t, wantPass, r.Expected, "%s -> %s expected column should be %v", source, dest, wantPass)
			assert.True(t, r.MatchedExpectation, "%s -> %s must match expectation", source, dest)
		}
	}
}

func findPair(t *testing.T, results []probeResult, source, dest string) probeResult {
	t.Helper()
	for _, r := range results {
		if r.Source == source && r.Destination == dest {
			return r
		}
	}
	t.Fatalf("probe pair %s -> %s not found in results", source, dest)
	return probeResult{}
}

func invokeProbe(t *testing.T, region, functionName string) []byte {
	t.Helper()
	return terratestaws.InvokeFunction(t, region, functionName, nil)
}

func waitForAllOnline(t *testing.T, region string, instanceIDs map[string]string) {
	t.Helper()
	const maxAttempts = 30
	const sleepBetween = 10 * time.Second

	client := terratestaws.NewSsmClient(t, region)

	_, err := retry.DoWithRetryE(t, "wait for all tier instances to register with SSM", maxAttempts, sleepBetween, func() (string, error) {
		ids := make([]*string, 0, len(instanceIDs))
		for _, id := range instanceIDs {
			ids = append(ids, aws.String(id))
		}
		out, describeErr := client.DescribeInstanceInformation(&ssm.DescribeInstanceInformationInput{
			Filters: []*ssm.InstanceInformationStringFilter{{
				Key:    aws.String("InstanceIds"),
				Values: ids,
			}},
		})
		if describeErr != nil {
			return "", describeErr
		}
		online := map[string]bool{}
		for _, info := range out.InstanceInformationList {
			if info.InstanceId != nil && info.PingStatus != nil && *info.PingStatus == "Online" {
				online[*info.InstanceId] = true
			}
		}
		missing := []string{}
		for _, id := range instanceIDs {
			if !online[id] {
				missing = append(missing, id)
			}
		}
		if len(missing) > 0 {
			return "", fmt.Errorf("%d instance(s) not yet Online: %v", len(missing), missing)
		}
		return "all online", nil
	})
	if err != nil {
		t.Fatalf("tier instances did not all register with SSM in time: %v", err)
	}
}
