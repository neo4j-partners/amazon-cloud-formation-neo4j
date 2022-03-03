# Advanced
These are advanced Cloud Formation Templates that cater to complex scenarios.  You probably only want to use these if you have some specific need for them.  If you don't, check out the AWS Marketplace listing or the [simple](../simple) template.

## Existing VPC
This will deploy into an existing VPC.  There are some prerequisites here:

* The VPC will need to have public subnets
* Enable "DNS hostnames" in the VPC
* Enable "Auto-assign public IPv4 address" within the public subnets
* You will have to specify both the VPC ID and the public subnet IDs in the deploy script or console
