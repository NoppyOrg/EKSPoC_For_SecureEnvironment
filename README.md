# EKS_ECS_reference
EKSとECKのリファレンス環境作成用のCFn




## ベースの構築
```
./run_cfn.sh PoC Iam create
./run_cfn.sh PoC VpcFunc create
./run_cfn.sh PoC VpcExter create
./run_cfn.sh PoC VpcPeer create
./run_cfn.sh PoC ExterSg create
./run_cfn.sh PoC Bastion create
./run_cfn.sh PoC Proxy create
./run_cfn.sh PoC Vpce create
./run_cfn.sh PoC Sg create
./run_cfn.sh PoC S3 create
./run_cfn.sh PoC Ecr create
./run_cfn.sh PoC DockerDev create
./run_cfn.sh PoC K8sMgr create
```

## EKSクラスター構築
```
＃パラメータ設定
PROFILE=<実行環境のプロファイルを指定>
REGION=ap-northeast-1
Env=PoC

EKS_CLUSTER_NAME=PoC-EksCluster
EKS_VERSION=1.14

#CloudFormationからの情報収集
EKS_SERVICE_ROLE=$(   aws --profile ${PROFILE} --output text cloudformation describe-stacks --stack-name ${Env}-Iam     --query 'Stacks[].Outputs[?OutputKey==`EksServiceRoleArn`].[OutputValue]' )
EKS_CLUSTER_SUBNET1=$(aws --profile ${PROFILE} --output text cloudformation describe-stacks --stack-name ${Env}-VpcFunc --query 'Stacks[].Outputs[?OutputKey==`PrivateSubnet1Id`].[OutputValue]' )
EKS_CLUSTER_SUBNET2=$(aws --profile ${PROFILE} --output text cloudformation describe-stacks --stack-name ${Env}-VpcFunc --query 'Stacks[].Outputs[?OutputKey==`PrivateSubnet2Id`].[OutputValue]' )
EKS_CLUSTER_SG=$(     aws --profile ${PROFILE} --output text cloudformation describe-stacks --stack-name ${Env}-Sg      --query 'Stacks[].Outputs[?OutputKey==`EksControlPlaneSGId`].[OutputValue]' )

#EKS クラスター作成
aws --profile ${PROFILE} --region ${REGION} eks create-cluster \
    --name ${EKS_CLUSTER_NAME} \
    --kubernetes-version ${EKS_VERSION} \
    --role-arn ${EKS_SERVICE_ROLE} \
    --logging '{"clusterLogging": [ { "types": ["api","audit","authenticator","controllerManager","scheduler"],"enabled": true } ]}' \
    --resources-vpc-config \
        subnetIds=${EKS_CLUSTER_SUBNET1},${EKS_CLUSTER_SUBNET2},securityGroupIds=${EKS_CLUSTER_SG},endpointPublicAccess=false,endpointPrivateAccess=true
```

#kubectlセットアップ in K8s 管理員インスタンス
```
# Setup proxy environment values
export http_proxy=http://FowardProxy:3128
export https_proxy=http://FowardProxy:3128

# Install kubectl
curl -o kubectl https://amazon-eks.s3-us-west-2.amazonaws.com/1.13.7/2019-06-11/bin/linux/amd64/kubectl
curl -o kubectl.sha256 https://amazon-eks.s3-us-west-2.amazonaws.com/1.13.7/2019-06-11/bin/linux/amd64/kubectl.sha256
openssl sha1 -sha256 kubectl
chmod +x ./kubectl
mkdir -p $HOME/bin && cp ./kubectl $HOME/bin/kubectl && export PATH=$HOME/bin:$PATH
echo 'export PATH=$HOME/bin:$PATH' >> ~/.bashrc

kubectl version --short --client

#
```


## Dockerイメージ作成＆レポジトリ登録
### Dockerイメージ作成用ディレクトリ作成
```
mkdir httpd-container
cd httpd-container
```

### Dockerfile作成
```
cat > Dockerfile << EOL
# setting base image
FROM centos:centos7

# Author
MAINTAINER cidermitaina

# install Apache http server
RUN ["yum",  "-y", "install", "httpd"]

# start httpd
CMD ["/usr/sbin/httpd", "-D", "FOREGROUND"]
EOL
```

### Docker build & 動作確認
```
docker build -t httpd-sample:ver01 --build-arg http_proxy=http://<ProxyIP>:3128 .
docker images

docker run -d -p 8080:80 httpd

curl http://localhost:8080
<html><body><h1>It works!</h1></body></html>
```
### 
Docker push
```
docker tag httpd-sample:ver01 709164018952.dkr.ecr.ap-northeast-1.amazonaws.com/poc-e-ecrre-1lainbr15149s:ver01

$(aws ecr get-login --no-include-email --region ap-northeast-1)

Login Succeeded

docker push 709164018952.dkr.ecr.ap-northeast-1.amazonaws.com/poc-e-ecrre-1lainbr15149s:ver01
```