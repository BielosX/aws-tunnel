#!/bin/bash

export AWS_PAGER=""

if [[ -z "$AWS_REGION" ]]; then
  export AWS_REGION="eu-west-1"
fi
if [[ -z "$PREFIX" ]]; then
  PREFIX="my"
fi
STACK_NAME="${PREFIX}-jump-box"

function deploy() {
  public_ip=$(curl -s ifconfig.me)
  if [[ -z "${SUBNET_ID}" ]]; then
    echo "Environment variable SUBNET_ID should be set."
    exit 255
  fi
  if [[ -z "${USER_PORT}" ]]; then
    echo "Environment variable USER_PORT should be set."
    exit 255
  fi
  if [[ -z "${DESTINATION_PORT}" ]]; then
    DESTINATION_PORT="$USER_PORT"
  fi
  output=$(aws ec2 describe-subnets --subnet-ids "$SUBNET_ID" 2> /dev/null)
  exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    echo "Subnet with id ${SUBNET_ID} not found"
    exit 255
  fi
  vpc_id=$(jq -r '.Subnets[0].VpcId' <<< "$output")
  echo "SubnetId: ${SUBNET_ID}, VpcId: ${vpc_id}, StackName: ${STACK_NAME}, UserPort: ${USER_PORT}, DestinationPort: ${DESTINATION_PORT}"
  aws cloudformation deploy --template-file jumpbox.yaml \
    --stack-name "$STACK_NAME" \
    --parameter-overrides VpcId="$vpc_id" \
    SubnetId="$SUBNET_ID" \
    UserPort="$USER_PORT" \
    DestinationPort="$DESTINATION_PORT" \
    FromIp="$public_ip" \
    NamePrefix="$PREFIX"
}

function tunnel() {
  if [[ -z "${ENDPOINT}" ]]; then
    echo "Environment variable ENDPOINT should bee set."
    exit 255
  fi
  outputs=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
    | jq -r '.Stacks[0].Outputs | map({ (.OutputKey|tostring): (.OutputValue|tostring) }) | add')
  rm -f temp-key
  rm -f temp-key.pub
  ssh-keygen -t rsa -f temp-key -q -N ""
  instance_id=$(jq -r '.InstanceId' <<< "$outputs")
  availability_zone=$(jq -r '.InstanceAZ' <<< "$outputs")
  aws ec2-instance-connect send-ssh-public-key \
      --instance-id "$instance_id" \
      --availability-zone "$availability_zone" \
      --instance-os-user ec2-user \
      --ssh-public-key file://temp-key.pub
  user_port=$(jq -r '.UserPort' <<< "$outputs")
  destination_port=$(jq -r '.DestinationPort' <<< "$outputs")
  instance_ip=$(jq -r '.InstancePublicIp' <<< "$outputs")
  ssh -y -o "StrictHostKeyChecking=no" \
    -o "IdentitiesOnly=yes" \
    -i temp-key \
    "ec2-user@${instance_ip}" -L "${user_port}:${ENDPOINT}:${destination_port}"
}

function destroy() {
  aws cloudformation delete-stack --stack-name "$STACK_NAME"
  while aws cloudformation describe-stacks --stack-name "$STACK_NAME" > /dev/null 2>&1
  do
    echo "Stack $STACK_NAME still exists. Destroying"
    sleep 10
  done
  echo "Stack $STACK_NAME removed"
}

case "$1" in
  "deploy") deploy ;;
  "destroy") destroy ;;
  "tunnel") tunnel ;;
esac