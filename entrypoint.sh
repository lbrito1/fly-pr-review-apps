#!/bin/sh -l

set -ex

if [ -n "$INPUT_PATH" ]; then
  # Allow user to change directories in which to run Fly commands.
  cd "$INPUT_PATH" || exit
fi

PR_NUMBER=$(jq -r .number /github/workflow/event.json)
if [ -z "$PR_NUMBER" ]; then
  echo "This action only supports pull_request actions."
  exit 1
fi

GITHUB_REPOSITORY_NAME=${GITHUB_REPOSITORY#$GITHUB_REPOSITORY_OWNER/}

EVENT_TYPE=$(jq -r .action /github/workflow/event.json)

# Default the Fly app name to pr-{number}-{repo_owner}-{repo_name}
app="${INPUT_NAME:-pr-$PR_NUMBER-$GITHUB_REPOSITORY_OWNER-$GITHUB_REPOSITORY_NAME}"
# Change underscores to hyphens.
app="${app//_/-}"
region="${INPUT_REGION:-${FLY_REGION:-iad}}"
org="${INPUT_ORG:-${FLY_ORG:-personal}}"
image="$INPUT_IMAGE"
config="${INPUT_CONFIG:-fly.toml}"
dockerfile="{$INPUT_DOCKERFILE:./Dockerfile}"
postgres_app="${INPUT_POSTGRES:-pr-$PR_NUMBER-$GITHUB_REPOSITORY_OWNER-$GITHUB_REPOSITORY_NAME-db}"

if ! echo "$app" | grep "$PR_NUMBER"; then
  echo "For safety, this action requires the app's name to contain the PR number."
  exit 1
fi

teardown() {
  if [ -n "$postgres_app" ]; then
    flyctl apps destroy "$postgres_app" -y || true
  fi
  flyctl apps destroy "$app" -y || true
}

setup() {
  # Deploy the Fly app, creating it first if needed.
  if ! flyctl status --app "$app"; then
    # Backup the original config file since 'flyctl launch' messes up the [build.args] section
    cp "$config" "$config.bak"
    flyctl launch --no-deploy --copy-config --name "$app" --image "$image" --region "$region" --org "$org" --dockerfile "$dockerfile" -y
    # Restore the original config file
    cp "$config.bak" "$config"
  fi
  if [ -n "$INPUT_SECRETS" ]; then
    echo $INPUT_SECRETS | tr " " "\n" | flyctl secrets import --app "$app"
  fi

  # Attach postgres cluster to the app if specified.
  if [ -n "$postgres_app" ]; then
    # Create postgres app if it does not already exist
    if ! flyctl status --app "$postgres_app"; then
      # We need a 4x machine to do the fork
      flyctl postgres create --name "$postgres_app" --region "$region" --org "$org" --fork-from frdm-db-staging --vm-size shared-cpu-4x --volume-size 10 --initial-cluster-size 1 || true

      # Once it is created, we can scale back to a smaller machine
      machine_id=$(fly machine ls -a "$postgres_app" -j | jq -r '.[0].id')
      fly machine update $machine_id --vm-memory 256 --vm-cpus 1 -a "$postgres_app" -y
    fi

    flyctl postgres attach "$postgres_app" --app "$app" --database-name frdm_staging -y || true
  fi

  # Trigger the deploy of the new version.
  echo "Contents of config $config file: " && cat "$config"
  if [ -n "$INPUT_VM" ]; then
    flyctl deploy --config "$config" --app "$app" --region "$region" --image "$image" --strategy immediate --ha=$INPUT_HA --vm-size "$INPUT_VMSIZE"
  else
    flyctl deploy --config "$config" --app "$app" --region "$region" --image "$image" --strategy immediate --ha=$INPUT_HA --vm-cpu-kind "$INPUT_CPUKIND" --vm-cpus $INPUT_CPU --vm-memory "$INPUT_MEMORY"
  fi

  # Make some info available to the GitHub workflow.
  flyctl status --app "$app" --json >status.json
  hostname=$(jq -r .Hostname status.json)
  appid=$(jq -r .ID status.json)
  echo "hostname=$hostname" >> $GITHUB_OUTPUT
  echo "url=https://$hostname" >> $GITHUB_OUTPUT
  echo "id=$appid" >> $GITHUB_OUTPUT
  echo "name=$app" >> $GITHUB_OUTPUT
}


if [ "$EVENT_TYPE" = "closed" ]; then
  # PR was closed - remove the Fly app if one exists and exit.
  teardown
  exit 0
else
  # PR was open or updated - deploy the server
  setup
fi
