#!/bin/sh
# Create/Update cloudformations
# Usage:
#   ./run_fcn.sh "Environment" "Stack" [create|update|create-change-set]]
#     "Environment" : specified environment (required)
#     "Stack"       : specified stack       (required)
#     [create|update|create-change-set] : create : Specify it when creating a new stack.
#                       not specify or update : specify if when update a stack.
#--------------------------------------------

# list of Environment
Envs[0]=PoC;    ProfileList[0]=ExSPoC
EnvsLast=1

#CloudFormation ServiceRole
Role="arn:aws:iam::709164018952:role/CloudFormationServiceRole"
#Role="NULL"   # If a Service Role for cloudformation does not exist.


#--------------
# list of stack
#--------------
# For Guest
Stacks[0]=Iam;        Dirs[0]="./IAM";           Templates[0]="iam.yaml"
Stacks[1]=VpcFunc;    Dirs[1]="./VPC";           Templates[1]="vpc-4subnets.yaml"
Stacks[2]=VpcExter;   Dirs[2]="./VPC";           Templates[2]="vpc-2subnets.yaml"
Stacks[3]=VpcPeer;    Dirs[3]="./VPC";           Templates[3]="vpcpeer.yaml"
#DMZ VPC
Stacks[4]=ExterSg;    Dirs[4]="./ExterResource"; Templates[4]="sg.yaml"
Stacks[5]=Bastion;    Dirs[5]="./ExterResource"; Templates[5]="bastion.yaml"
Stacks[6]=Proxy;      Dirs[6]="./ExterResource"; Templates[6]="proxy.yaml"
#Function VPC
Stacks[7]=Vpce;       Dirs[7]="./SgAndVpce";     Templates[7]="vpce.yaml"
Stacks[8]=Sg;         Dirs[8]="./SgAndVpce";     Templates[8]="sg.yaml"
Stacks[9]=S3;         Dirs[9]="./S3";            Templates[9]="s3.yaml"
Stacks[10]=Ecr;       Dirs[10]="./Ecr";          Templates[10]="ecr.yaml"
Stacks[11]=DockerDev; Dirs[11]="./Instances";    Templates[11]="docker_dev_instance.yaml"
Stacks[12]=K8sMgr;    Dirs[12]="./Instances";    Templates[12]="k8smgr.yaml"
StacksLAST=12

#--------------------------------------------
function help(){
    echo './run_fcn.sh "Environment" ["Stack"|ALL] [create|update|create-change-set]'
    echo "  Environments: ${Envs[@]}"
    echo "  Stacks:       ${Stacks[@]}"
    echo "  Command:      ${Command}"
}

function do_cfn_core(){
    # check parameter
    if [ "A${Environment}" = "ANULL" -o "A${Environment}" = "A" -o \
         "A${Profile}"     = "ANULL" -o "A${Profile}"     = "A" -o \
         "A${Stack}"       = "ANULL" -o "A${Stack}"       = "A" -o \
         "A${Dir}"         = "ANULL" -o "A${Dir}"         = "A" -o \
         "A${Template}"    = "ANULL" -o "A${Template}"    = "A" -o \
         "A${Command}"     = "ANULL" -o "A${Command}"     = "A" ]; then
        echo 'Invalid argument(s).'"  "$@
        help
        echo "Environment=${Environment}"
        echo "Profile=${Profile}"
        echo "Stack=${Stack}"
        echo "Dir=${Dir}"
        echo "TemplateBody=${Template}"
        exit 1
    fi

    TemplateBody="${Dir}/${Template}"
    CliInputJson="${Dir}/InputParameter-${Environment}-${Stack}"

    ./run_cfn_core.sh "${Profile}" "${Role}" "${Environment}" "${Stack}" "${TemplateBody}" "${CliInputJson}" "${Command}"
    ret=$?
    #echo "core=$ret"
    return ${ret}
}

#-------------------------------------------
Environment="NULL"
Stack="NULL"
Dir="NULL"
Template="NULL"
Command="NULL"
ALLSTACK="FALSE"

# set Environment
for i in $(seq 0 ${EnvsLast})
do
    if [ "A${1}" = "A${Envs[$i]}" ]; then
        Environment=${Envs[$i]}
        Profile=${ProfileList[$i]}
        break
    fi
done 
    
# set Stack & Template
if [ "A${2}" = "AALL" ]; then
    ALLSTACK="TRUE"
else
    for i in $(seq 0 ${StacksLAST})
    do
        if [ "A${2}" = "A${Stacks[$i]}" ]; then
            Stack=${Stacks[$i]}
            Dir=${Dirs[$i]}
            Template=${Templates[$i]}
            break
        fi
    done
fi 

# set command
Command=${3}

# do cfn_core
if [ "${ALLSTACK}" = "TRUE" ]; then
    for i in $(seq 0 ${StacksLAST})
    do
        if [ "A${Stacks[$i]}" != "A" ]; then
            Stack=${Stacks[$i]}
            Dir=${Dirs[$i]}
            Template=${Templates[$i]}

            do_cfn_core
            ret=$?
            #echo "loop=${ret}"
            if [ ${ret} -ne 0 ]; then
                echo "abend!!"
                break
            fi
        fi
    done
else
    do_cfn_core
    ret=$?
    #echo "shot=${ret}"
fi

exit ${ret}
