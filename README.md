# CloudFormation: EKS PoC For Secure Environment
セキュアな環境でEKSを利用するための検証用環境を作成するCloudFormationテンプレートです。
# 作成環境
![CFn_configuration](./Documents/EKS_PoC.png)

# 作成手順
## (1)ベースの構築
### (1)-(a) CloudFormation用のサービスロールの作成
CloudFormationのスタック作成時にサービスに貸与する、CloudFormation実行用のサービスロールを作成します。
```shell
export Profile=XXXXXXXX
cat > cfn_policy.json << EOL
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "",
            "Effect": "Allow",
            "Principal": {
                "Service": "cloudformation.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
EOL
aws --profile ${Profile} iam create-role --role-name CloudFormationServiceRole --assume-role-policy-document file://cfn_policy.json
```
作成したIAMロールのArn(` "Arn": "arn:aws:iam::999999999999:role/CloudFormationServiceRole",`)を控えておきます。
### (1)-(b) デプロイ用シェルのプロファイルとCloudFormationServiceRoleの設定
デプロイ用のシェル(run_cfn.sh)に実行環境のプロファイルと先ほど作成した CloudFormationServiceRoleのArnを設定します。
- run_cfn.shをエディタで開き下記を編集します。
```shell

# list of Environment
Envs[0]=PoC;  ProfileList[0]=XXXXXXX #実行する端末に設定しているプロファイル名に修正する(デフォルトを利用したい場合は、defaultと指定)
EnvsLast=0

#CloudFormation ServiceRole
Role="arn:aws:iam::999999999999:role/CloudFormationServiceRole" #先ほど作成したCloudFormationServiceRoleのArnを設定

```
### (1)-(c) CloudFormationデプロイ 
```shell
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
```shell
# Setup proxy environment values
FowardProxyIP=<FowardProxy IP Address>
FowardProxyPort=3128
```
### (2)-(b) Update AWS CLI
```shell
curl -x http://${FowardProxyIP}:${FowardProxyPort} \
     -o "get-pip.py" \
     "https://bootstrap.pypa.io/get-pip.py" 
sudo python get-pip.py --proxy="http://${FowardProxyIP}:${FowardProxyPort}"

pip install --upgrade --user awscli --proxy="http://${FowardProxyIP}:${FowardProxyPort}"
echo 'export PATH=$HOME/.local/bin:$PATH' >> ~/.bashrc
. ~/.bashrc

aws configure set region ap-northeast-1
aws configure set output json

aws --version
```
### (2)-(c) EKSクラスター作成
```shell
＃パラメータ設定
PROFILE=default
REGION=ap-northeast-1
Env=PoC

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
```shell
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
```shell
export https_proxy=http://${FowardProxyIP}:${FowardProxyPort}
export no_proxy=169.254.169.254

PROFILE=default
REGION=ap-northeast-1
EKS_CLUSTER_NAME=PoC-EksCluster

# kubectl用のconfig取得
aws --profile ${PROFILE} --region ${REGION} eks update-kubeconfig --name ${EKS_CLUSTER_NAME}
unset https_proxy no_proxy

#kubectlコマンドからのk8sマスターノード接続確認
kubectl get svc
```

## (3) k8sマスターノードへ、WorkerNodeのインスタンスRoleArnを追加
WorkerNodeを作成し、その後WorkerNodeがEKSクラスター(マスターノードのクラスター)にノード登録されるよう、WorkerNodeのインスタンスロールを追加する。
### (3)-(a) WorkerNodeのCloudFormation Stackデプロイ
CloudFormation作業環境で、WorkerNodeのStackをデプロイする
```shell
./run_cfn.sh PoC EksWorker create
```
### (3)-(b) k8sマスターノードのaws-auth ConfigMap設定
EKSクラスター(マスターノードのクラスター)にノード登録されるよう、ConfigMapにWorkerNodeのインスタンスロールを追加する。
作業は、高権限付与インスタンス(HighAuth)を利用する。
```shell
FowardProxyIP=<FowardProxy IP Address>
FowardProxyPort=3128

PROFILE=default
REGION=ap-northeast-1
Env=PoC

#aws-auth ConfigMapのダウンロード
curl -x http://${FowardProxyIP}:${FowardProxyPort} \
     -o aws-auth-cm.yaml \
     https://amazon-eks.s3-us-west-2.amazonaws.com/cloudformation/2019-02-11/aws-auth-cm.yaml


#CloudFormationからWorkerNodeのインスタンスロールARNを取得
aws --profile ${PROFILE} --output text cloudformation describe-stacks --stack-name ${Env}-Iam     --query 'Stacks[].Outputs[?OutputKey==`EksWorkerNodeInstanceRoleArn`].[OutputValue]'

# aws-auth-cm.yaml編集 
# "<ARN of instance role (not instance profile)>"をWorkerNodeのインスタンスロールARNに修正
vi aws-auth-cm.yaml

中略
data:
  mapRoles: |
    - rolearn: <ARN of instance role (not instance profile)>
以下略

# aws-auth-cm.yamlの適用
kubectl apply -f aws-auth-cm.yaml

＃WorkerNode状態確認
kubectl get nodes --watch
```

## (4) k8sマスターノードへ、K8s管理者(利用者サイドの管理者)のIAMロールを登録
作業は、高権限付与インスタンス(HighAuth)を利用する。
```sh
#AWS CLI用のパラメータ設定
PROFILE=default
REGION=ap-northeast-1
Env=PoC

#k8s管理者用のIAMロールのARN取得
aws --profile ${PROFILE} --output text cloudformation describe-stacks --stack-name ${Env}-Iam     --query 'Stacks[].Outputs[?OutputKey==`ManagerInstanceRoleArn`].[OutputValue]'

#aws-auth ConfigMapを開く
kubectl edit -n kube-system configmap/aws-auth
```
configmap/aws-authを以下の、data配下に新しいロールまたはユーザを追加する。
インスタンスロールの場合は、mapRolesの配下に追加、今回はないがIAMユーザの場合は、mapUsers:の配下に追加する。
詳細は、https://docs.aws.amazon.com/ja_jp/eks/latest/userguide/add-user-role.html 参照
```yaml
apiVersion: v1
data:
  mapRoles: |
    - rolearn: arn:aws:iam::709164018952:role/PoC-Iam-EksWorkerNodeInstanceRole-EXOJDNQYOIQX
      username: system:node:{{EC2PrivateDNSName}}
      groups:
        - system:bootstrappers
        - system:nodes
    - userarn: arn:aws:iam::555555555555:role/PoC-Iam-ManagerInstanceRole-LJSZQBR3HBVR
      username: admin
      groups:
        - system:masters
kind: ConfigMap
metadata:
  annotations:
    kubectl.kubernetes.io/last-applied-configuration: |
<以下略>
```

## (5) k8s管理用端末へのkubectlセットアップ
(2)-(a),(b)と、(2)-(d),(e)を参照し、aws cliのアップデートとkubectlのセットアップを行う。

## (6) k8s環境セットアップ完了
以上で、k8s環境のセットアップが完了する。
以下は、コンテナを作成し、Podを作成する手順である。


## (7) Dockerイメージ作成＆レポジトリ登録
### (7)-(a) Dockerイメージ作成用ディレクトリ作成
```sh
mkdir httpd-container
cd httpd-container
```

### (7)-(b) Dockerfile作成
```sh
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

### (7)-(c) Docker build & 動作確認
```
docker build -t httpd-sample:ver01 --build-arg http_proxy=http://<ProxyIP>:3128 .
docker images

docker run -d -p 8080:80 httpd

curl http://localhost:8080
<html><body><h1>It works!</h1></body></html>
```
### (7)-(d) ECRへのDockerイメージのプッシュ 
Docker push
```sh
docker tag httpd-sample:ver01 709164018952.dkr.ecr.ap-northeast-1.amazonaws.com/poc-e-ecrre-1lainbr15149s:latest

$(aws ecr get-login --no-include-email --region ap-northeast-1)

Login Succeeded

docker push 709164018952.dkr.ecr.ap-northeast-1.amazonaws.com/poc-e-ecrre-1lainbr15149s:latest
```

## (8) k8s 基本的なpodの作成と削除
EKSの管理端末で操作します。
### (8)-(a) ECRレポジトリの確認
```shell
aws ecr describe-repositories
* repositoryUriの内容を控えます。
```
### (8)-(b) Podの作成・確認・削除
```shell
cat > httpd-pod.yaml << EOL
apiVersion: v1
kind: Pod
metadata:
  name: httpd-pod
spec:
  containers:
    - name: httpd-container
      image: 709164018952.dkr.ecr.ap-northeast-1.amazonaws.com/poc-e-ecrre-1lainbr15149s:latest
      ports:
      - containerPort: 80
EOL
# Podの作成
kubectl create -f httpd-pod.yaml

# Podの確認(STATUSが、READYが1/1になり、Runningになっていることを確認)
kubectl get pod

# Podの削除
kubectl delete pod httpd-pod
```
## (9) k8s CNIを付与したPodの作成と削除
https://docs.aws.amazon.com/ja_jp/eks/latest/userguide/cni-custom-network.html

### (9)-(a) CNI カスタムネットワークを設定
aws-nodeデーモンセットに、AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFGを追加します。

```
kubectl edit daemonset -n kube-system aws-node
```
```
...
    spec:
      containers:
      - env:
        - name: AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG
          value: "true"
        - name: AWS_VPC_K8S_CNI_LOGLEVEL
          value: DEBUG
        - name: MY_NODE_NAME
...
```
### (9)-(b) WorkerNodeの再起動
WorkNodeを再起動(手動停止し、AutoScalingでインスタンス新規作成)し、CNI設定を有効化します。
```shell
INSTANCE_IDS=(`aws --output text ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --filters "Name=tag:Name,Values=*EksCluster-Worker-Nodes"` )
for i in "${INSTANCE_IDS[@]}"
do
	echo "Terminating EC2 instance $i ..."
	aws ec2 terminate-instances --instance-ids $i
done
```
### (9)-(c) CDRの確認
最新のversionでは、CDRが既にインストールされているので、確認だけ行う
```
kubectl get crd
```
実行例
```
NAME                               CREATED AT
eniconfigs.crd.k8s.amazonaws.com   2019-03-07T20:06:48Z
```
### (9)-(d) サブネットごとの ENIConfig カスタムリソース作成

```shell
#サブネットID, Pod用セキュリティグループ情報の取得
SUBNETID1=$(aws --output text ec2 describe-subnets --query 'Subnets[*].SubnetId' --filters "Name=tag:Name,Values=PrivateSub1")
SUBNETID2=$(aws --output text ec2 describe-subnets --query 'Subnets[*].SubnetId' --filters "Name=tag:Name,Values=PrivateSub2")

SECURITYGROUPID1=$(aws --output text ec2 describe-security-groups --query 'SecurityGroups[*].GroupId' --filters "Name=tag:Name,Values=PoC-EksPodSG")

# PrivateSub1用ENIConfig カスタムリソース用YAML
cat > custom-pod-netconfig-PrivateSub1.yaml << EOL
apiVersion: crd.k8s.amazonaws.com/v1alpha1
kind: ENIConfig
metadata:
 name: privatesub1-pod-netconfig
spec:
 subnet: $SUBNETID1
 securityGroups:
 - $SECURITYGROUPID1
EOL

# PrivateSub2用ENIConfig カスタムリソース用YAML
cat > custom-pod-netconfig-PrivateSub2.yaml << EOL
apiVersion: crd.k8s.amazonaws.com/v1alpha1
kind: ENIConfig
metadata:
 name: privatesub2-pod-netconfig
spec:
 subnet: $SUBNETID2
 securityGroups:
 - $SECURITYGROUPID1
EOL

#作成したカスタムリソースの適用
kubectl apply -f custom-pod-netconfig-PrivateSub1.yaml
kubectl apply -f custom-pod-netconfig-PrivateSub2.yaml

#適用したカスタムリソースの確認
kubectl get ENIConfig

#チェック
INSTANCE_PRIVATE_DNS=$(aws --output text ec2 describe-instances --query 'Reservations[*].Instances[*].PrivateDnsName' --filters "Name=tag:Name,Values=*EksCluster-Worker-Nodes")
for i in "${INSTANCE_PRIVATE_DNS[@]}"
do
	echo "Terminating EC2 instance $i ..."
	kubectl annotate node $i k8s.amazonaws.com/eniConfig=privatesub1-pod-netconfig
  echo "---"
  kubectl annotate node $i k8s.amazonaws.com/eniConfig=privatesub2-pod-netconfig
done




クラスター用に新しい ENIConfig カスタムリソースを定義します。
```shell
cat > ENIConfig.yaml << EOL
apiVersion: apiextensions.k8s.io/v1beta1
kind: CustomResourceDefinition
metadata:
  name: eniconfigs.crd.k8s.amazonaws.com
spec:
  scope: Cluster
  group: crd.k8s.amazonaws.com
  version: v1alpha1
  names:
    plural: eniconfigs
    singular: eniconfig
    kind: ENIConfig
EOL

kubectl apply -f ENIConfig.yaml
```



# 番外編
## dockerのログ確認
```
sudo journalctl -f -u docker
```