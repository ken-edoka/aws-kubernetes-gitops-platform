#!/bin/bash

# update server
sudo yum update -y

# install amazon ssm agent and session manager plugin
sudo dnf install -y https://s3."${region}".amazonaws.com/amazon-ssm-"${region}"/latest/linux_amd64/amazon-ssm-agent.rpm
curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/linux_64bit/session-manager-plugin.rpm" -o "session-manager-plugin.rpm"
sudo yum install -y session-manager-plugin.rpm
sudo systemctl start amazon-ssm-agent
sudo systemctl enable amazon-ssm-agent

# install jenkins
sudo yum install wget git python3-pip -y
sudo wget -O /etc/yum.repos.d/jenkins.repo https://pkg.jenkins.io/rpm/jenkins.repo
sudo yum upgrade
# Add required dependencies for the jenkins package
sudo yum install fontconfig java-21-openjdk -y
sudo yum install jenkins -y
sudo systemctl enable jenkins
sudo systemctl start jenkins
sudo usermod -aG jenkins ec2-user

# install docker
sudo yum install -y yum-utils
sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
sudo yum install docker-ce -y
sudo service docker start
sudo systemctl start docker
sudo systemctl enable docker
# add jenkins and ec2-user to docker group
sudo usermod -aG docker ec2-user
sudo usermod -aG docker jenkins
sudo chmod 777 /var/run/docker.sock

# install aws cli
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
sudo yum install -y unzip
unzip awscliv2.zip
sudo ./aws/install

# install newrelic infrastructure agent
curl -Ls https://download.newrelic.com/install/newrelic-cli/scripts/install.sh | bash && \
sudo NEW_RELIC_API_KEY="${newrelic_api_key}" \ 
NEW_RELIC_ACCOUNT_ID="${newrelic_account_id}" \
NEW_RELIC_REGION="EU" \
/usr/local/bin/newrelic install -y
sudo hostnamectl set-hostname Jenkins-Server