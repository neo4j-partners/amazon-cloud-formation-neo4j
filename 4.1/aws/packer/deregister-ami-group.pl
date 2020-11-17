#!/usr/bin/perl
#
# Deregister a batch of AWS AMIs.   **Use with care!**
# In debugging, quite a few images may be created that ultimately aren't
# needed.  This script is just a utility to help clean up multi-zone litter
# which would otherwise be left behind.
# 
# Works nicely with the output of packer.
#
# Usage:
# echo "
# ap-northeast-1: ami-0d96dcc4e312fa802
# ap-northeast-2: ami-09948d9dd1634aeea
# ap-south-1: ami-0176461de4f735c03
# ap-southeast-1: ami-028e5eb964cd20dc7
# ap-southeast-2: ami-01c24bc7e777c3a08
# eu-central-1: ami-0db5e8632356248f4
# eu-west-1: ami-0a568bb7fcf953556
# eu-west-3: ami-0bd97e67fd06c8300
# sa-east-1: ami-0baeb731dbf452dad
# us-east-1: ami-07c7a545c1cdea042
# us-east-2: ami-07c46c8b38e06e393
# us-west-1: ami-0caf44f9e935db243
# us-west-2: ami-0fff496cc9501bdd5
# " | ./deregister-ami-group.pl

while (my $line = <STDIN>) {
   chomp($line);
   if ($line =~ m/^([^\s]+): (ami-[^\s]+)$/) {
      my $region = $1;
      my $ami = $2;
      print "Deregistering $ami from $region...\n";
      print `aws ec2 deregister-image --image-id $ami --region $region`;
   }
}
