# EKS_ECS_reference
EKSとECKのリファレンス環境作成用のCFn



# 作成手順
## (1)ベースの構築
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
./run_cfn.sh PoC HighAuth create
```

## (2)EKSクラスター作成
高権限付与インスタンス(HighAuth)を利用し、セットアップ＆クラスタ作成を行う
### (2)-(a)事前設定(curl用 Proxy設定)
```
# Setup proxy environment values
FowardProxyIP=<FowardProxy IP Address>
FowardProxyPort=3128
```
### (2)-(b) Update AWS CLI
```
curl "https://bootstrap.pypa.io/get-pip.py" -o "get-pip.py" -x http://${FowardProxyIP}:${FowardProxyPort}
sudo python get-pip.py --proxy="http://${FowardProxyIP}:${FowardProxyPort}"

pip install --upgrade --user awscli --proxy="http://${FowardProxyIP}:${FowardProxyPort}"
echo 'export PATH=$HOME/.local/bin:$PATH' >> ~/.bashrc
. ~/.bashrc

aws configure set region ap-northeast-1
aws configure set output json

```
### (2)-(c) EKSクラスター作成
```
＃パラメータ設定
PROFILE=default
REGION=ap-northeast-1

EKS_CLUSTER_NAME=PoC-EksCluster
EKS_VERSION=1.14

#CloudFormationからの情報収集
EKS_SERVICE_ROLE=$(   aws --profile ${PROFILE} --output text cloudformation describe-stacks --stack-name ${Env}-Iam     --query 'Stacks[].Outputs[?OutputKey==`EksServiceRoleArn`].[OutputValue]' )
EKS_CLUSTER_SUBNET1=$(aws --profile ${PROFILE} --output text cloudformation describe-stacks --stack-name ${Env}-VpcFunc --query 'Stacks[].Outputs[?OutputKey==`PrivateSubnet1Id`].[OutputValue]' )
EKS_CLUSTER_SUBNET2=$(aws --profile ${PROFILE} --output text cloudformation describe-stacks --stack-name ${Env}-VpcFunc --query 'Stacks[].Outputs[?OutputKey==`PrivateSubnet2Id`].[OutputValue]' )
EKS_CLUSTER_SG=$(     aws --profile ${PROFILE} --output text cloudformation describe-stacks --stack-name ${Env}-Sg      --query 'Stacks[].Outputs[?OutputKey==`EksControlPlaneSGId`].[OutputValue]' )

#Check Parameter
echo -e "EKS_SERVICE_ROLE=${EKS_SERVICE_ROLE}\nEKS_CLUSTER_SUBNET1=${EKS_CLUSTER_SUBNET1}\nEKS_CLUSTER_SUBNET2=${EKS_CLUSTER_SUBNET2}\nEKS_CLUSTER_SG=${EKS_CLUSTER_SG}"

#EKS クラスター作成
export https_proxy=http://${FowardProxyIP}:${FowardProxyPort}
export no_proxy=169.254.169.254
aws --profile ${PROFILE} --region ${REGION} eks create-cluster \
    --name ${EKS_CLUSTER_NAME} \
    --kubernetes-version ${EKS_VERSION} \
    --role-arn ${EKS_SERVICE_ROLE} \
    --logging '{"clusterLogging": [ { "types": ["api","audit","authenticator","controllerManager","scheduler"],"enabled": true } ]}' \
    --resources-vpc-config \
        subnetIds=${EKS_CLUSTER_SUBNET1},${EKS_CLUSTER_SUBNET2},securityGroupIds=${EKS_CLUSTER_SG},endpointPublicAccess=false,endpointPrivateAccess=true
unset https_proxy no_proxy
```
### (2)-(d) Install the kubectl
```
curl -x http://${FowardProxyIP}:${FowardProxyPort} \
     -o kubectl \
     https://amazon-eks.s3-us-west-2.amazonaws.com/1.13.7/2019-06-11/bin/linux/amd64/kubectl
curl -x http://${FowardProxyIP}:${FowardProxyPort} \
     -o kubectl.sha256 \
     https://amazon-eks.s3-us-west-2.amazonaws.com/1.13.7/2019-06-11/bin/linux/amd64/kubectl.sha256
if [ $(openssl sha1 -sha256 kubectl|awk '{print $2}') = $(cat kubectl.sha256 | awk '{print $1}') ]; then echo OK; else echo NG; fi

chmod +x ./kubectl
mkdir -p $HOME/bin && mv ./kubectl $HOME/bin/kubectl && export PATH=$HOME/bin:$PATH
echo 'export PATH=$HOME/bin:$PATH' >> ~/.bashrc

kubectl version --short --client
```
### (2)-(e) Configuer kubectl
kubeconfigを手動作成する場合は、こちら(https://docs.aws.amazon.com/ja_jp/eks/latest/userguide/create-kubeconfig.html)を参照
```
export https_proxy=http://${FowardProxyIP}:${FowardProxyPort}
export no_proxy=169.254.169.254

# kubectl用のconfig取得
aws --profile ${PROFILE} --region ${REGION} eks update-kubeconfig --name ${EKS_CLUSTER_NAME}
unset https_proxy no_proxy

#kubectlコマンドからのk8sマスターノード接続確認
kubectl get svc
```

## (3)EKSクラスターへ利用者向け管理者を追加




### kubectlセットアップ in K8s 管理員インスタンス




# kubectlセットアップ in K8s 管理員インスタンス
## 事前設定(curl用 Proxy設定)
```
# Setup proxy environment values
export http_proxy=http://FowardProxy:3128
export https_proxy=http://FowardProxy:3128
export no_proxy=169.254.169.254
```

## AWS CLI update
```
curl "https://bootstrap.pypa.io/get-pip.py" -o "get-pip.py"
sudo python get-pip.py --proxy="http://FowardProxy:3128"

pip install --upgrade --user awscli --proxy="http://FowardProxy:3128"
echo 'export PATH=$HOME/.local/bin:$PATH' >> ~/.bashrc
. ~/.bashrc

sudo python get-pip.py --proxy=“http://10.2.64.53:3128
pip install --upgrade --user awscli --proxy=http://10.2.64.53:3128

```


## Install kubectl
```
curl -o kubectl https://amazon-eks.s3-us-west-2.amazonaws.com/1.13.7/2019-06-11/bin/linux/amd64/kubectl
curl -o kubectl.sha256 https://amazon-eks.s3-us-west-2.amazonaws.com/1.13.7/2019-06-11/bin/linux/amd64/kubectl.sha256
openssl sha1 -sha256 kubectl
chmod +x ./kubectl
mkdir -p $HOME/bin && mv ./kubectl $HOME/bin/kubectl && export PATH=$HOME/bin:$PATH
echo 'export PATH=$HOME/bin:$PATH' >> ~/.bashrc

kubectl version --short --client
```
## Install aws-iam-authenticator
```
curl -o aws-iam-authenticator https://amazon-eks.s3-us-west-2.amazonaws.com/1.13.7/2019-06-11/bin/linux/amd64/aws-iam-authenticator
curl -o aws-iam-authenticator.sha256 https://amazon-eks.s3-us-west-2.amazonaws.com/1.13.7/2019-06-11/bin/linux/amd64/aws-iam-authenticator.sha256
openssl sha1 -sha256 aws-iam-authenticator

chmod +x ./aws-iam-authenticator
mkdir -p $HOME/bin && mv ./aws-iam-authenticator $HOME/bin/aws-iam-authenticator && export PATH=$HOME/bin:$PATH

aws-iam-authenticator help
```
## setup kubectl(manual)
```
mkdir -p ~/.kube

cat > ~/.kube/kubeconfig << EOL
apiVersion: v1
clusters:
- cluster:
    server: <endpoint-url>
    certificate-authority-data: <base64-encoded-ca-cert>
  name: kubernetes
contexts:
- context:
    cluster: kubernetes
    user: aws
  name: aws
current-context: aws
kind: Config
preferences: {}
users:
- name: aws
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1alpha1
      command: aws-iam-authenticator
      args:
        - "token"
        - "-i"
        - "<cluster-name>"
        # - "-r"
        # - "<role-arn>"
      # env:
        # - name: AWS_PROFILE
        #   value: "<aws-profile>"
EOL
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