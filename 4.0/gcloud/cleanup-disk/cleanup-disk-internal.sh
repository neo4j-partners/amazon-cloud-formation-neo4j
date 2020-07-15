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

mount_point="/mnt/disks/cleared"

cleanup_root_script_path="${mount_point}/opt/cleanup-root.sh"

cat > "${cleanup_root_script_path}" << 'EOF'
#!/bin/bash -eu
# Check if disk is already cleaned up
if [[ -f /var/lib/google/google_users ]]; then
  # Delete all users automatically created by GCP.
  cat /var/lib/google/google_users | xargs -n1 userdel -r

  # Remove the file containing list of all GCP users.
  rm /var/lib/google/google_users
fi

# Delete all log files.
find /var/log/ -type f -delete
EOF

# mount cleaned-up disk
sudo mkdir -p "${mount_point}"
sudo mount -o discard,defaults /dev/sdb1 "${mount_point}"
sudo chmod a+w "${mount_point}"

# create cleanup script for root user on mounted disk
sudo touch "${cleanup_root_script_path}"
sudo chmod a+rwx "${cleanup_root_script_path}"
echo "${cleanup_script}" > "${cleanup_root_script_path}"

# execute root cleanup script in environment switched to cleaned-up disk
sudo chroot "${mount_point}" /opt/cleanup-root.sh

# unmount the disk
sudo umount "${mount_point}"

# shutdown the instance
sudo shutdown -h now
