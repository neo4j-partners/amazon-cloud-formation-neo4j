# Testing Cloud Images

I use shell scripts in this directory to test VM-based cloud images.  In general, you'll just need to set a few environment variables with the endpoint and login information for the instance
you created, and the script does the rest.

# Caveats

Testing attempts writes.  Do not run tests against real databases, just temp deploys.

