#!/bin/bash

set -eu

cd $(dirname $0)

CfnTemplate="./cfn_yaml/ses_log.yaml"

Region=${AWS_DEFAULT_REGION:-ap-northeast-1}

### -------------------------------- ###
###     ドメインなどを記入
### -------------------------------- ###
StackPrefix="example"
Domain="example.com"

### -------------------------------- ###
###  SES Log用のKinesis Firehose作成
### -------------------------------- ###
CfnStackName="${StackPrefix}-SES-Log"
AccountID=$(aws sts get-caller-identity --query "Account" --output text)
SesLogsBucketName=`echo "${CfnStackName}-${Region}" | tr '[:upper:]' '[:lower:]'`
ConfigurationSetName=$(echo ${Domain} | sed -e "s/\./-/g")
ConfigurationSetArn="arn:aws:ses:${Region}:${AccountID}:configuration-set/${ConfigurationSetName}"

### Kinesis設定項目
ExpirationInDays="400"
SizeInMBs="5"
IntervalInSeconds="300"
CompressionFormat="GZIP"

aws cloudformation deploy \
    --region ${Region} \
    --stack-name ${CfnStackName} \
    --template-file ${CfnTemplate} \
    --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
    --no-fail-on-empty-changeset \
    --parameter-overrides \
    SesLogsBucketName=${SesLogsBucketName} \
    ExpirationInDays=${ExpirationInDays} \
    SizeInMBs=${SizeInMBs} \
    IntervalInSeconds=${IntervalInSeconds} \
    CompressionFormat=${CompressionFormat} \
    ConfigurationSetArn=${ConfigurationSetArn} 


### -------------------------------- ###
###     Configuration Setの設定
###  ※東京でCFn対応していないのでCLIで
### -------------------------------- ###
if [[ -z $(aws ses describe-configuration-set \
    --configuration-set-name "${ConfigurationSetName}" \
    --output json \
    2>/dev/null || :) ]]; then

    # configuration set作成
    aws ses create-configuration-set \
        --configuration-set Name=${ConfigurationSetName} \
        > /dev/null

    CfnOutput=$(aws cloudformation describe-stacks --stack-name "${CfnStackName}")

    DeliveryStreamARN=$(echo "${CfnOutput}" \
    | jq '.Stacks[].Outputs[] | select(.ExportName == "SesLogDeliveryStream-Arn-'${CfnStackName}'") | .OutputValue' \
    | tr -d '"')

    IAMRoleARN=$(echo "${CfnOutput}" \
    | jq '.Stacks[].Outputs[] | select(.ExportName == "SesLogRole-Arn-'${CfnStackName}'") | .OutputValue' \
    | tr -d '"')

    # event destination
    EventDestination="{
        \"Name\": \"${ConfigurationSetName}-KinesisFirehose\",
        \"Enabled\": true,
        \"MatchingEventTypes\": [\"send\", \"reject\", \"bounce\", \"complaint\", \"delivery\", \"open\", \"click\", \"renderingFailure\"],
        \"KinesisFirehoseDestination\": {
            \"IAMRoleARN\": \"${IAMRoleARN}\",
            \"DeliveryStreamARN\": \"${DeliveryStreamARN}\"
        }
    }"

    # configuration setにevent destination（配信先情報）を設定
    aws ses create-configuration-set-event-destination \
        --configuration-set-name ${ConfigurationSetName} \
        --event-destination "${EventDestination}" \
        > /dev/null

    # SESにconfiguration setを紐付け（デフォルト設定セット）
    aws sesv2 put-email-identity-configuration-set-attributes \
        --email-identity "${Domain}" \
        --configuration-set-name ${ConfigurationSetName} \
        > /dev/null
fi

echo "Finished."