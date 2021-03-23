# Cleanup Disk

This directory contains internal GCP shell scripts.  After preparing a VM instance,
it's recommended to cleanup the disk prior to prepping an image.

Step 5: Clean up the instance's boot disk from Cloud Platform accounts data. One of the possible options is to use a script that will automatically create a new micro instance, attach the disk there, and cleanup Cloud Platform users data and log files from /var/log directory:

```
curl -s https://storage.googleapis.com/partner-utils/disk-cleanup/cleanup-disk.zip
unzip cleanup-disk.zip
chmod u+x cleanup-disk.sh
./cleanup-disk.sh -d <DISK_NAME> -p <PROJECT_NAME> -z <ZONE_NAME>
```

After the disk is cleaned in this way, an image can be prepped:

```
gcloud compute images create neo4j-cc-node-vX \
  --source-disk some-disk \
  --family neo4j-cc
```
