#!/bin/bash
#
# Quick script to display all regions and associated availability zones, for inspecting current AWS map.
# Also, don't want to deploy to region with < 3 AZs.
for region in $(aws ec2 describe-regions --query 'Regions[].{Name:RegionName}' --output text) ; do
   echo "Region: $region"
   aws ec2 describe-availability-zones --query 'AvailabilityZones[].{Name:ZoneName}' --output text --region "$region"
   echo ""
done
