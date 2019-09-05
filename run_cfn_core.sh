#!/bin/sh

#for aws cli
Profile="${1:-NULL}"
Role="${2:-NULL}"

#for cloudformation
Environment="${3:-NULL}"
Stack="${4:-NULL}"
TemplateBody_template="${5:-NULL}"
CliInputJson_template="${6:-NULL}"
Action=${7:-NULL}

#Check args
if [ "x${Action}" = "xcreate" ];
then
    Action="create-stack"
    Wait="stack-create-complete"
elif [ "x${Action}" = "xupdate" ]; 
then
    Action="update-stack"
    Wait="stack-update-complete"
elif [ "x${Action}" = "xcreate-change-set" ];
then
    Action="create-change-set"
    Wait=""
else
    echo "but action(${Action})"
    exit 1
fi

#Set file path
StackName="${Environment}-${Stack}"
TemplateBody="${TemplateBody_template}"
CliInputJson="${CliInputJson_template}.json"

#Check Files
if [ ! -f ${TemplateBody} -o ! -f ${CliInputJson} ];
then
    echo "file(s) not found."
    echo "template-body = ${TemplateBody}"
    echo "cli-input-json = ${CliInputJson}"
    exit 1
fi

#Submit CloudFormation------
if [ "${Action}" = "create-stack" -o "${Action}" = "update-stack" ];
then
    if [ "${Role}" != "NULL" ]
    then
        aws --profile "${Profile}" \
            cloudformation "${Action}" \
                --stack-name "${StackName}" \
                --template-body "file://${TemplateBody}" \
                --cli-input-json "file://${CliInputJson}" \
                --capabilities CAPABILITY_NAMED_IAM \
                --role-arn "${Role}";
    else
        aws --profile "${Profile}" \
            cloudformation "${Action}" \
                --stack-name "${StackName}" \
                --template-body "file://${TemplateBody}" \
                --cli-input-json "file://${CliInputJson}" \
                --capabilities CAPABILITY_NAMED_IAM;
    fi
    aws --profile "${Profile}" \
        cloudformation wait ${Wait} \
            --stack-name ${StackName};
    ret=$?

    if [ ${ret} -eq 0 ]
    then
        echo "Detect stack drift."
        aws --profile "${Profile}" \
            cloudformation detect-stack-drift \
                --stack-name ${StackName};
    fi
elif [ "${Action}" = "create-change-set" ];
then
    if [ "${Role}" != "NULL" ]
    then
        aws --profile "${Profile}" \
            cloudformation "${Action}" \
                --stack-name "${StackName}" \
                --template-body "file://${TemplateBody}" \
                --cli-input-json "file://${CliInputJson}" \
                --capabilities CAPABILITY_NAMED_IAM \
                --role-arn "${Role}" \
                --change-set-name "${StackName}-$(date '+%Y%m%d-%H%M%S')";
    else
        aws --profile "${Profile}" \
            cloudformation "${Action}" \
                --stack-name "${StackName}" \
                --template-body "file://${TemplateBody}" \
                --cli-input-json "file://${CliInputJson}" \
                --capabilities CAPABILITY_NAMED_IAM \
                --change-set-name "${StackName}-$(date '+%Y%m%d-%H%M%S')";
    fi
    ret=$?
fi

echo ${ret}
exit ${ret}
