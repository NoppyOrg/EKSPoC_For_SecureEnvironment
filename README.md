# CloudFormation: EKS PoC For Secure Environment
セキュアな環境でEKSを利用するための検証用環境を作成するCloudFormationテンプレートです。
# 作成環境
![CFn_configuration](./Documents/EKS_PoC.png)

# 作成手順
## (1)事前設定
### (1)-(a) 作業環境の準備
下記を準備します。
* bashが利用可能な環境(LinuxやMacの環境)
* aws-cliのセットアップ
* AdministratorAccessポリシーが付与され実行可能な、aws-cliのProfileの設定

### (1)-(b) gitのclone
```shell
git clone https://github.com/Noppy/EKSPoC_For_SecureEnvironment.git
cd EKSPoC_For_SecureEnvironment
```

### (1)-(c) CLI実行用の事前準備
これ以降のAWS-CLIで共通で利用するパラメータを環境変数で設定しておきます。
```shell
export PROFILE=<PoC環境のAdmministratorAccess権限が実行可能なプロファイル>
export REGION="ap-northeast-1"

#プロファイルの動作テスト
#COMPUTE_PROFILE
aws --profile ${PROFILE} sts get-caller-identity
```
## (2)Network準備
### (2)-(a) VPC作成
```shell
aws --profile ${PROFILE} --region ${REGION} \
    cloudformation create-stack \
        --stack-name EksPoc-VPC \
        --template-body "file://./src/vpc-2az-4subnets.yaml" \
        --parameters "file://./src/vpc.conf" \
        --capabilities CAPABILITY_IAM ;
```
### (2)-(b) SecurityGroup作成
```shell
aws --profile ${PROFILE} --region ${REGION} \
    cloudformation create-stack \
        --stack-name EksPoc-SG \
        --template-body "file://./src/sg.yaml"
```
### (3)-(c) VPCエンドポイント作成
```shell
aws --profile ${PROFILE} --region ${REGION} \
    cloudformation create-stack \
        --stack-name EksPoc-Vpce \
        --template-body "file://./src/vpce.yaml" 
```

## (3)IAMロール&KMSキー作製
### (3)-(a) IAMロール作成
必要なIAMロールを準備します。
- AWS管理ポリシーを付与する場合おはこのタイミングで付与します。
- またカスタマー管理ポリシーまたはインラインポリシーでリソースの特定が不要な場合もこのタイミングでポリシーを付与します。
- リソースの特定が必要な場合(例えばECRのリポジトリのARNが必要など)は、リソース作成時に個別にポリシーを付与します。
```shell
aws --profile ${PROFILE} --region ${REGION} \
    cloudformation create-stack \
        --stack-name EksPoc-IAM \
        --template-body "file://./src/iam.yaml" \
        --capabilities CAPABILITY_IAM ;
```
### (3)-(b) KMS CMKキー作成
```shell
aws --profile ${PROFILE} --region ${REGION} \
    cloudformation create-stack \
        --stack-name EksPoc-KMS \
        --template-body "file://./src/kms.yaml" ;
```
## (4)インスタンス準備
```shell
#Bastion & DockerSG & kubectl
aws --profile ${PROFILE} --region ${REGION} \
    cloudformation create-stack \
        --stack-name EksPoc-Instances \
        --template-body "file://./src/instances.yaml" 
```

## (5)dockerイメージ作成とECRへの格納
### (5)-(a) ECRリポジトリ作成
```shell
aws --profile ${PROFILE} --region ${REGION} \
    cloudformation create-stack \
        --stack-name EksPoc-Ecr \
        --template-body "file://./src/ecr.yaml" \
        --capabilities CAPABILITY_IAM ;
```
### (5)-(b) docker環境準備
#### (i) DockerDevインスタンスへSSMでOSログイン
```shell
#DockerDevインスタンスのインスタンスID取得
DockerDevID=$(aws --profile ${PROFILE} --region ${REGION} --output text \
    cloudformation describe-stacks \
        --stack-name EksPoc-Instances \
        --query 'Stacks[].Outputs[?OutputKey==`DockerDevId`].[OutputValue]')
echo "DockerDevID = $DockerDevID"

#SSMによるOSログイン
aws --profile ${PROFILE} --region ${REGION} \
    ssm start-session \
        --target "${DockerDevID}"
```
#### (ii) docker環境のセットアップ
```shell
#ec2-userにスイッチ
sudo -u ec2-user -i
```
```shell
# Setup AWS CLI
REGION=$( \
    TOKEN=`curl -s \
        -X PUT \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" \
        "http://169.254.169.254/latest/api/token"` \
    && curl \
        -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/placement/availability-zone | sed -e 's/.$//')
aws configure set region ${REGION}
aws configure set output json

#動作テスト(作成したECRレポジトリがリストに表示されることを確認)
aws ecr describe-repositories
```
```shell
#dockerのセットアップ
sudo yum install -y docker
sudo systemctl start docker
sudo systemctl enable docker
sudo usermod -a -G docker ec2-user
```
```shell
#usermod設定をセッションに反映するためsudoし直す
exit

#ec2-userにスイッチ
sudo -u ec2-user -i

#ec2-userユーザのセカンドグループにdockerが含まれていることを確認する
id

#dockerテスト(下記コマンドでサーバ情報が参照できることを確認)
docker info
```
#### (iii)dockerイメージ作成
```shell
#コンテナイメージ用のディレクトリを作成し移動
mkdir httpd-container
cd httpd-container

#データ用フォルダを作成
mkdir src

#dockerコンテナの定義ファイルを作成
cat > Dockerfile << EOL
# setting base image
FROM php:8.1-apache

RUN set -x && \
    apt-get update 

COPY src/ /var/www/html/
EOL

#
cat > src/index.php << EOL
<html>
  <head>
    <title>PHP Sample</title>
  </head>
  <body>
    <?php echo gethostname(); ?>
  </body>
</html>
EOL

#Docker build
docker build -t httpd-sample:ver01 .
docker images

#コンテナの動作確認
docker run -d -p 8080:80 httpd-sample:ver01
docker ps #コンテナが稼働していることを確認

#接続確認
# <title>PHP Sample</title>という文字が表示されたら成功！！
curl http://localhost:8080
```
#### (iv)dockerイメージ作成とECRリポジトリへの登録
```shell
REPO_URL=$( aws --output text \
    ecr describe-repositories \
        --repository-names ekspoc-repo \
    --query 'repositories[].repositoryUri' ) ;
echo "
REPO_URL = ${REPO_URL}
"

# ECR登録用のタグを作成
docker tag httpd-sample:ver01 ${REPO_URL}:latest
docker images #作成したtagが表示されていることを確認

#ECRログイン
#"Login Succeeded"と表示されることを確認
aws ecr get-login-password | docker login --username AWS --password-stdin ${REPO_URL}

#イメージのpush
docker push ${REPO_URL}:latest

#ECR上のレポジトリ確認
aws ecr list-images --repository-name ekspoc-repo
```
#### (v)ログアウト
```shell
exit  #ec2-userからの戻る
exit  #SSMからのログアウト
```

## (5)EKSコントロールプレーン作成とk8s管理者環境の準備
以下の作業は、Bastion兼高権限用インスタンスで作業します。
これは作成したEKSクラスターの初期状態でkubectlで操作可能なIAMは、EKSクラスターを作成した権限のみのためである。

### (5)-(a) 高権限(Bastion)インスタンス環境準備
#### (i) 高権限インスタンスへSSMでOSログイン
```shell
#DockerDevインスタンスのインスタンスID取得
HighAuthID=$(aws --profile ${PROFILE} --region ${REGION} --output text \
    cloudformation describe-stacks \
        --stack-name EksPoc-Instances \
        --query 'Stacks[].Outputs[?OutputKey==`BastionAndHighAuthorityId`].[OutputValue]')
echo "HighAuthID = $HighAuthID"

#SSMによるOSログイン
aws --profile ${PROFILE} --region ${REGION} \
    ssm start-session \
        --target "${HighAuthID}"
```
#### (ii) AWS CLIセットアップ
```shell
#ec2-userにスイッチ
sudo -u ec2-user -i
```
```shell
# Setup AWS CLI
REGION=$( \
    TOKEN=`curl -s \
        -X PUT \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" \
        "http://169.254.169.254/latest/api/token"` \
    && curl \
        -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/placement/availability-zone | sed -e 's/.$//')
aws configure set region ${REGION}
aws configure set output json
```
### (5)-(b) EKSクラスター作成(k8sコントロールプレーン作成)
```shell
aws cloudformation create-stack \
        --stack-name EksPoc-EksControlPlane \
        --template-body "file://./src/eks_control_plane.yaml" 
```















```shell
EKS_CLUSTER_NAME=EksPoC-Cluster
EKS_VERSION=1.22

#CloudFormationからの情報収集
EKS_SERVICE_ROLE=$(aws --output text cloudformation \
    describe-stacks --stack-name EksPoc-IAM \
    --query 'Stacks[].Outputs[?OutputKey==`EksServiceRoleArn`].[OutputValue]' )
EKS_KMS_KEY_ARN=$(aws --output text cloudformation \
    describe-stacks --stack-name EksPoc-KMS \
    --query 'Stacks[].Outputs[?OutputKey==`KeyArn`].[OutputValue]' )
EKS_CLUSTER_SUBNET1=$(aws --output text cloudformation \
    describe-stacks --stack-name EksPoc-VPC \
    --query 'Stacks[].Outputs[?OutputKey==`PrivateSubnet1Id`].[OutputValue]' )
EKS_CLUSTER_SUBNET2=$(aws --output text cloudformation \
    describe-stacks --stack-name EksPoc-VPC \
    --query 'Stacks[].Outputs[?OutputKey==`PrivateSubnet2Id`].[OutputValue]' )
    
EKS_CLUSTER_SG=$(aws --output text cloudformation \
    describe-stacks --stack-name EksPoc-SG \
    --query 'Stacks[].Outputs[?OutputKey==`EksCtlPlaneSGId`].[OutputValue]' )

#Check Parameter
echo -e "
EKS_SERVICE_ROLE    = ${EKS_SERVICE_ROLE}
EKS_KMS_KEY_ARN     = ${EKS_KMS_KEY_ARN}
EKS_CLUSTER_SUBNET1 = ${EKS_CLUSTER_SUBNET1}
EKS_CLUSTER_SUBNET2 = ${EKS_CLUSTER_SUBNET2}
EKS_CLUSTER_SG      = ${EKS_CLUSTER_SG}"

```
#### (ii) EKSクラスター作成
```shell
#クラスター作成
aws eks create-cluster \
    --name ${EKS_CLUSTER_NAME} \
    --kubernetes-version ${EKS_VERSION} \
    --role-arn ${EKS_SERVICE_ROLE} \
    --logging '
        {"clusterLogging": [
            { "types": ["api","audit","authenticator","controllerManager","scheduler"],
              "enabled": true 
            }
        ]}' \
    --encryption-config '
        [
            {
                "resources":["secrets"],
                "provider":{
                    "keyArn":"'"${EKS_KMS_KEY_ARN}"'"
                }
            }
        ]' \
    --resources-vpc-config \
        subnetIds=${EKS_CLUSTER_SUBNET1},${EKS_CLUSTER_SUBNET2},securityGroupIds=${EKS_CLUSTER_SG},endpointPublicAccess=false,endpointPrivateAccess=true ;

```
### (5)-(c) EksAdmin環境の準備
#### (i)高権限環境へのkubectlセットアップ
EksAdmin環境でkubectl操作を可能にするためには、まずHightAuth環境でkubeconfigの初期設定の初期設定を行う必要がある。そのためにまずHighAuth環境でkubectlをセットアップする。
```shell
# kubectlのダウンロード
curl -o kubectl https://s3.us-west-2.amazonaws.com/amazon-eks/1.22.6/2022-03-09/bin/linux/amd64/kubectl

curl -o kubectl.sha256 https://s3.us-west-2.amazonaws.com/amazon-eks/1.22.6/2022-03-09/bin/linux/amd64/kubectl.sha256

#チェックサム確認
if [ $(openssl sha1 -sha256 kubectl|awk '{print $2}') = $(cat kubectl.sha256 | awk '{print $1}') ]; then echo OK; else echo NG; fi
```
```shell
#kubectlのパーミッション付与と移動
chmod +x ./kubectl
mkdir -p $HOME/bin && mv ./kubectl $HOME/bin/kubectl && export PATH=$HOME/bin:$PATH
echo 'export PATH=$HOME/bin:$PATH' >> ~/.bashrc

#動作テスト
kubectl version --short --client
```
#### (ii)高権限環境のkubectlをコントロールプレーンに接続
```shell
# kubectl用のconfig取得
aws eks update-kubeconfig --name ${EKS_CLUSTER_NAME}

#kubectlコマンドからのk8sマスターノード接続確認
kubectl get svc
```
#### (iii)aws-auth ConfigMapのクラスターへの適用
- [aws-auth設定の最新情報はこちらを参照](https://docs.aws.amazon.com/ja_jp/eks/latest/userguide/add-user-role.html#aws-auth-configmapg)

aws-auth ConfigMap が適用済みであるかどうかを確認します。
```shell

kubectl describe configmap -n kube-system aws-auth]
```
`Error from server (NotFound): configmaps "aws-auth" not found`というエラーが表示された場合は、以下のステップを実行してストック ConfigMap を適用します。
```shell
curl -o aws-auth-cm.yaml https://amazon-eks.s3.us-west-2.amazonaws.com/cloudformation/2020-10-29/aws-auth-cm.yaml
```
CloudFormationからWorkerNodeのインスタンスロールARNを取得
```shell
aws --output text cloudformation describe-stacks \
    --stack-name EksPoc-IAM \
    --query 'Stacks[].Outputs[?OutputKey==`EC2k8sWorkerRoleArn`].[OutputValue]'
```
aws-auth-cm.yaml編集 
`<ARN of instance role (not instance profile)>`をWorkerNodeのインスタンスロールARNに修正
```shell
vi aws-auth-cm.yaml

中略
data:
  mapRoles: |
    - rolearn: <ARN of instance role (not instance profile)>
以下略
```
aws-authを適用します。
```shell
# aws-auth-cm.yamlの適用
kubectl apply -f aws-auth-cm.yaml

# WorkerNode状態確認
kubectl get nodes --watch
```






EksAdminのロールをk8sのマップに追加
```shell
#k8s管理者用のIAMロールのARN取得
aws --output text cloudformation describe-stacks \
    --stack-name EksPoc-IAM \
    --query 'Stacks[].Outputs[?OutputKey==`EC2kubectlRoleArn`].[OutputValue]'

#aws-auth ConfigMapを開く
kubectl edit -n kube-system configmap/aws-auth