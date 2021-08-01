FROM debian:stable-slim

MAINTAINER bledi.feshti@neotechnology.com

RUN apt -qq update && apt upgrade -y
RUN apt install -qq -y python3.7 vim python3-pip wget unzip curl gettext-base
RUN pip3 install awscli jinja2 s3cmd pipenv

RUN mkdir /app
WORKDIR /app
<<<<<<< HEAD
ADD .. /app
=======
ADD . /app
>>>>>>> neo4j-v4.3.0

RUN wget https://releases.hashicorp.com/packer/1.4.1/packer_1.4.1_linux_amd64.zip
RUN unzip packer_1.4.1_linux_amd64.zip -d /bin/
RUN chmod +x /bin/packer
ENTRYPOINT ["/app/entrypoint.sh"]