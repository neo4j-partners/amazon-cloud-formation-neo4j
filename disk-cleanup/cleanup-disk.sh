#!/bin/bash -eu
#
# Copyright 2017 Google Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

function usage() {
  echo "Usage:"
  echo -e "$0 --disk=<disk-name> --project=<project-name> --zone=<zone-name>"
  echo -e "- disk-name:      disk name in short format, without project"
  echo -e "                  nor zone specifiers"
  echo -e "- [project-name]: project, where disk is located;"
  echo -e "                  default: gcloud config get-value project"
  echo -e "- [zone-name]:    zone, where disk is located;"
  echo -e "                  default: gcloud config get-value compute/zone"
}

# utility function - wait until command exected with expected result
# (not more than 5 minutes)
function wait_for() {
  expected_result="${1}"
  shift
  start_time="$(date '+%s')"
  while [[ "${execution_time:-0}" -lt 300 ]]; do
    actual_result="$("${@}")"
    execution_time="$(($(date '+%s') - ${start_time}))"
    if [[ "${expected_result}" != "${actual_result}" \
          &&  "${execution_time}" -lt 300 ]]; then
      sleep 5
    else
      return 0
    fi
  done
  return 1
}

# read parameters
while [[ ${#} -gt 0 ]] ; do
  case "${1}" in
    -d | --disk)
      disk_name="${2}"
      shift
      ;;
    -p | --project)
      project_name="${2}"
      shift
      ;;
    -z | --zone)
      zone_name="${2}"
      shift
      ;;
    -h | --help)
      usage
      exit 0
  esac
  shift
done

# check if required disk name is set
if [[ -z "${disk_name:-}" ]]; then
  echo "ERROR: disk name not specified."
  usage
  exit 1
fi

# read default value for project name if it wasn't passed with flag
project_name="${project_name:-$(gcloud config get-value project)}"
if [[ -z "${project_name:-}" ]]; then
  echo "ERROR: could not read default value of the project from gcloud"
  usage
  exit 1
fi

# read default value for zone name if it wasn't passed with flag
zone_name="${zone_name:-$(gcloud config get-value compute/zone)}"
if [[ -z "${zone_name:-}" ]]; then
  echo "ERROR: could not read default value of the zone from gcloud"
  usage
  exit 1
fi

echo "Clean up process initiated for disk: ${disk_name}..."
echo "- project: ${project_name}"
echo "- zone: ${zone_name}"

machine_type="f1-micro"
instance_name="disk-cleaner-$(date +%Y%m%d-%H%M%S)"

gcloud compute disks list --project "${project_name}" --filter="name:(${disk_name}) NOT name:(cc-core-follower-2) zone:(${zone_name})" --format "get(name)" | wc -l
num_disks_found=$(gcloud compute disks list --project "${project_name}" --filter="name:(${disk_name}) NOT name:(cc-core-follower-2) zone:(${zone_name})" --format "get(name)" | wc -l)
echo "num disks found " $num_disks_found
if [ -z "${num_disks_found}" ]; then
  echo "ERROR: disk \"${disk_name}\" could not be found in project"
  echo "       \"${project_name}\" and zone: \"${zone_name}\"."
  exit 1
fi

echo "Disk \"${disk_name}\" found, proceeding with temporary instance \
creation..."

function remove_cleaner_instance() {
  echo "Removing temporary instance..."

  gcloud compute instances delete "${instance_name}" \
    --project "${project_name}" \
    --zone "${zone_name}" \
    --quiet

  echo "Temporary instance removed."
}

# Create instance with the disk attached and run a startup script that will
# clean the disk and shutdown the machine after
gcloud compute instances create "${instance_name}" \
  --project "${project_name}" \
  --zone "${zone_name}" \
  --machine-type "${machine_type}" \
  --disk name="${disk_name}" \
  --metadata-from-file startup-script=cleanup-disk-internal.sh

# Mark instance removal operation as automatically executed before script ends.
trap "remove_cleaner_instance" EXIT SIGINT SIGQUIT

# Wait until instance has done its job and terminated
wait_for TERMINATED gcloud compute instances list \
  --project "${project_name}" \
  --filter "name~\"^${instance_name}\$\"" \
  --format "get(status)"

echo "Disk clean-up process completed..."
