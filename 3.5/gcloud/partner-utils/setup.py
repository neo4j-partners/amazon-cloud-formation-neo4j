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
"""Setup configuration for Cloud Partner Tools."""

from setuptools import setup

LONG_DESCRIPTION = ('partner_tools is a Python application that lets'
                    ' you add licenses for the Google Cloud Platform'
                    ' from the command line.')

# Configure the required packages and scripts to install, depending on
# Python version and OS.
REQUIRED_PACKAGES = ['google-api-python-client']

CONSOLE_SCRIPTS = ['gcloud-partner = image_creator:main',]

PARTNER_TOOLS_VERSION = '1.0.0'

setup(
    name='partner_tools',
    version=PARTNER_TOOLS_VERSION,
    description='Google Cloud Partner command-line tool',
    url='https://cloud.google.com/partners',
    download_url='https://cloud.google.com/sdk',
    license='Apache 2.0',
    author='Google Inc.',
    author_email='cloud-partners@google.com',
    long_description=LONG_DESCRIPTION,
    zip_safe=True,
    keywords='google partners onboard',
    classifiers=[
        'Environment :: Console',
        'Intended Audience :: Developers',
        'Intended Audience :: End Users/Desktop',
        'License :: OSI Approved :: Apache Software License',
        'Operating System :: MacOS :: MacOS X',
        'Operating System :: Microsoft :: Windows',
        'Operating System :: POSIX :: Linux',
        'Programming Language :: Python :: 3',
        'Topic :: Software Development :: Libraries',
        'Topic :: Software Development :: Libraries :: Python Modules',
    ],
    scripts=['image_creator.py'],
    entry_points={'console_scripts': CONSOLE_SCRIPTS,},
    install_requires=REQUIRED_PACKAGES,)
