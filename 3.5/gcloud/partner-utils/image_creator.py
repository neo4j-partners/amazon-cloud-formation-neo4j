#!/usr/bin/python

# Copyright 2017 Google Inc. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import argparse
import collections
import logging
import re
import sys
import time
from googleapiclient import discovery
from googleapiclient import errors
from oauth2client.client import Error as OAuth2ClientError
from oauth2client.client import GoogleCredentials

DISK_URI = '/projects/{project}/zones/{zone}/disks/{disk}'
INSTANCE_URI = '/projects/{project}/zones/{zone}/instances/{instance}'
LICENSE_URI = '/projects/{project}/global/licenses/{license}'
IMAGE_URI = '/projects/{project}/global/images/{image}'
LICENSE_REGEX = re.compile('[a-z]([a-z0-9-]+)(/)([a-z0-9-]+)')
YES_INPUT = set(['y', 'ye', 'yes'])
NO_INPUT = set(['n', 'no', ''])


def MakeDiskURI(project, zone, disk):
  return DISK_URI.format(project=project, zone=zone, disk=disk)


def MakeInstanceURI(project, zone, instance):
  return INSTANCE_URI.format(project=project, zone=zone, instance=instance)


def MakeLicenseURI(project, license_name):
  return LICENSE_URI.format(project=project, license=license_name)


def MakeImageURI(project, image):
  return IMAGE_URI.format(project=project, image=image)


def SpinningCursor():
  while True:
    for cursor in '|/-\\':
      yield cursor


def CheckLicenses(license_ids):
  """Check pattern of license to make sure it conforms."""

  # Checking if the license had the public project and productname
  license_list = []

  # Check pattern for all license(s).
  for licenses in license_ids:
    pattern_check = LICENSE_REGEX.match(licenses)
    if pattern_check:
      project = (pattern_check.group(0)).split('/')[0]
      solution = pattern_check.group(3)
      license_list.append(MakeLicenseURI(project, solution))
    else:
      print(licenses,
            'does not match license pattern required to create image.',
            'Please check the license information entered..',
            'License info shoud be: your-public-project-name/solution-name',
            'Incase you do not have this information please reach out to:',
            'cloud-partner@google.com')
      sys.exit(1)

  return license_list


def GetComputeService():
  """Check that user has access to a project."""

  try:
    credentials = GoogleCredentials.get_application_default()
  except OAuth2ClientError as err:
    print(err)
    print(
        'Unable to retrieve default credentials, please see',
        # pylint: disable=line-too-long
        'https://developers.google.com/identity/protocols/application-default-credentials#howtheywork',
        # pylint: disable=line-too-long
        'and https://cloud.google.com/sdk/gcloud/reference/auth/application-default/login'
    )
    print('To install the Google Cloud SDK please refer to',
          'https://cloud.google.com/sdk/downloads')
    sys.exit(1)
  return discovery.build('compute', 'v1', credentials=credentials)


def CreateImage(compute, project, image_name, disk, description, license_ids,
                family):
  """Create the image and insert license."""

  req_body_dict = {
      'name': image_name,
      'description': description,
      'sourceDisk': disk,
      'licenses': license_ids,
      'family': family
  }
  image_uri = MakeImageURI(project, image_name)
  try:
    insert = compute.images().insert(
        project=project, body=req_body_dict).execute()
  except errors.HttpError as err:
    if err.resp['status'] == '401':
      print(err.resp['status'], 'was encountered. Possible reasons include',
            'the resource you are trying to access does not exist or you',
            'are not authorized to access this resource.')
    elif err.resp['status'] == '403':
      print(err.resp['status'], 'was encountered. Possible reasons for this',
            'could be that you are not authorized to access this resource. Try',
            'generating application default credentials with `gcloud auth',
            'application-default login`')
    elif err.resp['status'] == '409':
      print('Resource', image_uri, 'already exists.')
    elif err.resp['status'] == '404' or err.resp['status'] == '503':
      print(err.resp['status'], 'was encountered. Possible reasons for this',
            'could be incorrect license ids. Check error message below and',
            'contact cloud-partners@google.com for help.')
      print(err)
    else:
      print('Unexpected error:', err, sys.exc_info()[0])
    sys.exit(1)
  WaitForOperation(compute, project, insert)
  print('Created', image_uri)
  return


def DeleteInstance(compute, instance_uri):
  """Get Disk details."""

  # Extract instance details from the uri
  project = instance_uri.split('/')[2]
  zone = instance_uri.split('/')[4]
  instance = instance_uri.split('/')[6]

  print('Checking if', instance_uri, 'is running ...')

  instance_detail = compute.instances().get(
      project=project, zone=zone, instance=instance).execute()

  if instance_detail['status'] == 'RUNNING':
    while True:
      choice = input('Stop instance? [y/n]: ').lower()
      if choice in YES_INPUT:
        print('Stopping', instance_uri, '...')
        stop = compute.instances().stop(
            project=project, zone=zone, instance=instance).execute()
        WaitForOperation(compute, project, stop)
        break
      elif choice in NO_INPUT:
        print(
            'To create image please stop the instance and re-run this script.')
        sys.exit()
      else:
        print('Please respond with "[{yes}]" or "[{no}]"'.format(
            yes=' | '.join(YES_INPUT), no=' | '.join(NO_INPUT)))
  else:
    print(instance_uri, 'is stopped.')

  # Check if disk is set to autoDelete
  device_name = instance_detail['disks'][0]['deviceName']
  disk_uri = MakeDiskURI(project, zone, device_name)
  print('Checking autoDelete for', disk_uri, '...')
  if instance_detail['disks'][0]['autoDelete']:
    print('Disabling autoDelete for', disk_uri, '...')
    no_disk_del = compute.instances().setDiskAutoDelete(
        project=project,
        zone=zone,
        instance=instance,
        autoDelete=False,
        deviceName=device_name).execute()
    WaitForOperation(compute, project, no_disk_del)
    print('Disabled autoDelete for', disk_uri)

  # Detach the disk
  print('Deleting', instance_uri, '...')
  del_instance = compute.instances().delete(
      project=project, zone=zone, instance=instance).execute()
  WaitForOperation(compute, project, del_instance)


def ResolveDiskURL(compute, project, disk_name):
  """Resolve the URI for the given disk_name."""

  print('Finding', MakeDiskURI(project, '*', disk_name), '...')
  users = ''
  disks_output = collections.namedtuple('results',
                                        ['disk_zone', 'selfLink', 'users'])

  # Putting in a filter to only fetch the disk_name in the json response
  filter_param = 'name eq ' + disk_name

  # Make the REST Call
  find_disk = compute.disks().aggregatedList(
      project=project, filter=filter_param).execute()

  # Search for the disk in all the zone
  for disk in list(find_disk['items'].values()):
    if 'disks' in disk:
      # There will be only one unique disk.
      disk_zone = (disk['disks'][0]['zone']).split('zones/')[1]
      self_link = (disk['disks'][0]['zone']).split('v1')[1]

      if 'users' in disk['disks'][0]:
        # Convert list to string
        users = (', '.join(disk['disks'][0]['users']).split('v1')[1])
      print('Found', MakeDiskURI(project, disk_zone, disk_name))
      return disks_output(disk_zone, self_link, users)
  print('Could not find', MakeDiskURI(project, '*', disk_name))
  sys.exit(1)


def WaitForOperation(compute, project, operation):
  """Wait for a given operation to finish."""

  # Extract info from the the operation object.
  name = operation['name']
  try:
    zone = operation['zone'].split('zones/')[1]
    wait_ops = compute.zoneOperations()
    req_dict = dict(project=project, zone=zone, operation=name)
  except KeyError:
    wait_ops = compute.globalOperations()
    req_dict = dict(project=project, operation=name)

  spinner = SpinningCursor()
  while True:
    try:
      result = wait_ops.get(**req_dict).execute()
      if result['status'] == 'DONE':
        if 'error' in result:
          raise Exception(result['error'])
        return result
    except errors.HttpError as err:
      if err.resp['status'] == '401' or err.resp['status'] == '403':
        print(err.resp['status'], 'was encountered. Possible reasons include',
              'the resource you are trying to access does not exist or you',
              'are not authorized to access this resource.')
      elif err.resp['status'] == '409':
        print('Resource already exists.')
      else:
        print('Unexpected error:', err, sys.exc_info()[0])
    sys.stdout.write(next(spinner))
    sys.stdout.flush()
    time.sleep(0.1)
    sys.stdout.write('\b')
    # To limit the API calls 1 per second.
    time.sleep(1)


def Run(project, disk, image_name, description, public_proj, licenses, family):
  """Do sanity checks."""

  compute = GetComputeService()
  license_ids = CheckLicenses(licenses)
  disk_url = ResolveDiskURL(compute, project, disk)
  disk_uri = MakeDiskURI(project, disk_url.disk_zone, disk)

  if disk_url.users:
    print('Detaching', disk_uri, '...')
    DeleteInstance(compute, disk_url.users)
  image_uri = MakeImageURI(project, image_name)
  print('Creating', image_uri, '...')

  # Lets create the image
  if public_proj:
    CreateImage(compute, public_proj, image_name, disk_uri, description,
                license_ids, family)
  else:
    CreateImage(compute, project, image_name, disk_uri, description,
                license_ids, family)


def main():
  logging.getLogger().setLevel(logging.ERROR)
  logging.basicConfig()
  license_help = ('License(s) to be attached to the image. '
                  'eg: partner-public-project/solution-name.'
                  ' Separate multiple keys with a comma.')
  parser = argparse.ArgumentParser(
      description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
  # TODO(jcking): warn on use of --project_id
  parser.add_argument(
      '--project',
      '--project_id',
      help='Your Google Cloud project ID.',
      required=True)
  parser.add_argument(
      '--disk', help='Name of sourceDisk for image creation.', required=True)
  parser.add_argument('--name', help='Image name.', required=True)
  parser.add_argument('--license', nargs='+', help=license_help, required=True)
  parser.add_argument('--description', help='Description for your image.')
  # TODO(jcking): warn on use of --public_project
  parser.add_argument(
      '--destination-project',
      '--public_project',
      help='Name of the destination project.')
  parser.add_argument('--family', help='The family of the image.')
  # Parse the arguments.
  args = parser.parse_args()
  Run(args.project, args.disk, args.name, args.description,
      args.destination_project, args.license, args.family)


if __name__ == '__main__':
  main()
