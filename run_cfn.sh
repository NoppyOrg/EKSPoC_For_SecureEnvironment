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
Stacks[0]=Iam;        Dirs[0]="./IAM";              Templates[0]="iam.yaml"
Stacks[1]=VpcFunc;    Dirs[1]="./VPC";              Templates[1]="vpc-4subnets.yaml"
Stacks[2]=VpcExter;   Dirs[2]="./VPC";              Templates[2]="vpc-2subnets.yaml"
Stacks[3]=VpcPeer;    Dirs[3]="./VPC";              Templates[3]="vpcpeer.yaml"
Stacks[4]=VpcHighAuth; Dirs[4]="./VPC";             Templates[4]="vpc-4subnets.yaml"
#DMZ VPC
Stacks[5]=ExterSg;    Dirs[5]="./ExterResource";    Templates[5]="sg.yaml"
Stacks[6]=Bastion;    Dirs[6]="./ExterResource";    Templates[6]="bastion.yaml"
Stacks[7]=Proxy;      Dirs[7]="./ExterResource";    Templates[7]="proxy.yaml"
#HightAutority VPC
#Stacks[8]=HighAuthSgVpce;  Dirs[8]="./HighAuthResource";  Templates[8]="sg_and_vpce.yaml"
#Stacks[9]=HighAuthProxy;   Dirs[9]="./HighAuthResource";  Templates[9]="proxy.yaml"
#Stacks[10]=HighAuthIns;    Dirs[10]="./HighAuthResource"; Templates[10]="highauth.yaml"

#Function VPC
Stacks[11]=Vpce;      Dirs[11]="./SgAndVpce";       Templates[11]="vpce.yaml"
Stacks[12]=Sg;        Dirs[12]="./SgAndVpce";       Templates[12]="sg.yaml"
Stacks[13]=S3;        Dirs[13]="./S3";              Templates[13]="s3.yaml"
Stacks[14]=Ecr;       Dirs[14]="./Ecr";             Templates[14]="ecr.yaml"
Stacks[15]=DockerDev; Dirs[15]="./Instances";       Templates[15]="docker_dev_instance.yaml"
Stacks[16]=K8sMgr;    Dirs[16]="./Instances";       Templates[16]="k8smgr.yaml"
Stacks[17]=HighAuth;  Dirs[17]="./Instances";       Templates[17]="highauth.yaml"
#EKS
Stacks[18]=Eks;       Dirs[18]="./Eks";             Templates[18]="eks.yaml"

StacksLAST=18

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
