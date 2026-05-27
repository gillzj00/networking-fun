// Package helpers wires shared Terratest plumbing for the networking-fun
// suite: per-test S3 state isolation, default tags every test resource
// must carry, and a cleanup-on-failure deferred teardown.
package helpers

import (
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/gruntwork-io/terratest/modules/random"
	"github.com/gruntwork-io/terratest/modules/terraform"
)

// AutoDeleteTTL is how far in the future the AutoDelete tag is set.
// Long enough for the test to apply+assert+destroy under normal latency,
// short enough that an aborted run leaves the janitor a small mop-up.
const AutoDeleteTTL = 1 * time.Hour

// DefaultRegion is used when AWS_REGION is unset in the environment.
const DefaultRegion = "us-east-2"

// EnvStateBucket names the env var the test reads for the S3 backend bucket.
// Tests fail loudly if it's missing — no implicit local state.
const EnvStateBucket = "TERRATEST_STATE_BUCKET"

// Run holds derived per-test values that fixtures need.
type Run struct {
	Region      string
	Suffix      string
	StateBucket string
	StateKey    string
	TTLIso      string
}

// NewRun builds a Run for the current test, asserting the env is configured.
func NewRun(t *testing.T) *Run {
	t.Helper()

	bucket := os.Getenv(EnvStateBucket)
	if bucket == "" {
		t.Fatalf("%s is required (set to the bootstrap tfstate bucket name)", EnvStateBucket)
	}

	region := os.Getenv("AWS_REGION")
	if region == "" {
		region = DefaultRegion
	}

	suffix := random.UniqueId()

	return &Run{
		Region:      region,
		Suffix:      suffix,
		StateBucket: bucket,
		StateKey:    fmt.Sprintf("terratest/%s/terraform.tfstate", suffix),
		TTLIso:      time.Now().UTC().Add(AutoDeleteTTL).Format("2006-01-02T15:04:05Z"),
	}
}

// TerraformOptions returns a fully-populated options struct for the given
// fixture directory: per-test S3 backend, default Terratest tags injected
// via Terraform vars, and a 5-minute lock timeout.
func (r *Run) TerraformOptions(t *testing.T, fixtureDir string, extraVars map[string]interface{}) *terraform.Options {
	t.Helper()

	vars := map[string]interface{}{
		"region":      r.Region,
		"suffix":      r.Suffix,
		"ttl_iso":     r.TTLIso,
		"owner_email": "5639243+gillzj00@users.noreply.github.com",
	}
	for k, v := range extraVars {
		vars[k] = v
	}

	return &terraform.Options{
		TerraformDir: fixtureDir,
		Vars:         vars,
		BackendConfig: map[string]interface{}{
			"bucket":       r.StateBucket,
			"key":          r.StateKey,
			"region":       r.Region,
			"encrypt":      true,
			"use_lockfile": true,
		},
		EnvVars: map[string]string{
			"AWS_REGION": r.Region,
		},
		NoColor:            true,
		MaxRetries:         2,
		TimeBetweenRetries: 5 * time.Second,
	}
}

// EnsureDestroy runs terraform destroy regardless of test outcome. Defer
// this immediately after InitAndApply so a panicking assertion still tears
// the run down. Logs (but does not fail) destroy errors — the janitor's
// AutoDelete sweep is the safety net of last resort.
func EnsureDestroy(t *testing.T, opts *terraform.Options) {
	t.Helper()
	if _, err := terraform.DestroyE(t, opts); err != nil {
		t.Logf("terraform destroy returned an error (janitor will sweep leftovers): %v", err)
	}
}
