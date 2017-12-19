#!/bin/bash
# Use the Amazon Linux AMI 2017.09.1 (HVM).
AMI_ID="ami-ff4ea59d"

# Required env vars:
# - NODE_VERSION
# - AWS_ACCESS_KEY_ID
# - AWS_SECRET_ACCESS_KEY
# - LAMBDA_FUNCTION_NAME
# - AWS_BUCKET
# - AWS_KEY_NAME

index=1
maxConnectionAttempts=20

# Poll the ssh server every 5 seconds attempting to connect. If no Connection
# can be made, retry the connection with a maximum number of attempts.
function checkInstanceReady {
    while (( $index <= $maxConnectionAttempts ))
    do
        ssh -q -o ConnectTimeout=1 -o BatchMode=yes -o StrictHostKeyChecking=no ec2-user@$1 exit
        case $? in
            (0) echo "Connection ready. Continuing..."; break ;;
            (*) echo "Connection not ready. Retrying connection to $1...";
        esac
        sleep 5
        ((index+=1))
    done
}

# Zip up given folder and upload to s3
function uploadFolderToS3 {
    echo "uploading: " $1 $2
    rm -rf $1*.zip
    zip -r $2 . -x "*.git*" "node_modules/*"
    aws s3 cp $2 s3://$AWS_BUCKET/$2
}

function deleteSecurityGroup {
    deleteSg=$(aws ec2 delete-security-group --group-id ${1})

    if [[ $deleteSg == *"An error occurred"* ]]; then
        echo "Error deleting security group. Retrying..."
        sleep 1
        deleteSecurityGroup $1
    fi
        echo "Deleted security group: ${sgId}"
}

# Add current ip to default security group, port 22.
namePrefix="lambda-deployer-$(date +%s)"
bundleName="$namePrefix.zip"
deployBundleName="$namePrefix-deploy.zip"
sgId=$(aws ec2 create-security-group --description "${namePrefix}" --group-name "${namePrefix}" | awk '/GroupId/ {print $2}' | sed "s/\"//g")
echo "Created security group: ${sgId}"

userIp=`curl ipinfo.io/ip`
aws ec2 authorize-security-group-ingress --group-id $sgId --protocol tcp --port 22 --cidr $userIp/32
echo "Added IP to port 22 on security group: ${userIp}"

# Start the instance and get it's id.
instanceId=$(aws ec2 run-instances --image-id ${AMI_ID} --count 1 --instance-type t1.micro --key-name ${AWS_KEY_NAME} --security-group-ids ${sgId} --query 'Instances[0].InstanceId' | sed "s/\"//g")

# Get the IP of the instance
instanceIp=$(aws ec2 describe-instances --instance-ids ${instanceId} --query 'Reservations[0].Instances[0].PublicIpAddress' | sed "s/\"//g")

echo "Instance ID is: ${instanceId}"
echo "Instance IP is: ${instanceIp}"

# Check the instance is ready to take an ssh connection.
checkInstanceReady $instanceIp

uploadFolderToS3 "lambda-deployer" $bundleName

# Instance is ready, so continue.
# Install Node on instance
ssh -o StrictHostKeyChecking=no ec2-user@$instanceIp "curl -o- https://raw.githubusercontent.com/creationix/nvm/v0.33.8/install.sh | bash && \
    . ~/.nvm/nvm.sh && \
    nvm install $NODE_VERSION"

# Download bundle onto instance and install dependencies, then re-upload to s3
ssh -o StrictHostKeyChecking=no ec2-user@$instanceIp "mkdir -p ~/$namePrefix && cd ~/$namePrefix && \
    AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY aws s3 cp s3://$AWS_BUCKET/$bundleName $bundleName && \
    unzip $bundleName -d . && \
    npm install && \
    zip -r $deployBundleName . && \
    AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY aws s3 cp $deployBundleName s3://$AWS_BUCKET/$deployBundleName"

# Clean up.
# Terminate the newly created instance and it's security group.
aws ec2 terminate-instances --instance-ids $instanceId
echo "Deleted instance: ${instanceId}"

deleteSecurityGroup $sgId

# Deploy to Lambda
aws lambda update-function-code --function-name $LAMBDA_FUNCTION_NAME --s3-bucket $AWS_BUCKET --s3-key $deployBundleName
