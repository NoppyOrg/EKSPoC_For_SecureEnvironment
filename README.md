# EKS Fully-Private Cluster without kesctl
インターネット接続のないVPC(VPC閉塞環境、プロキシ接続もなし)環境で、EKSクラスターを利用するためのセットアップの手順(ハンズオン)です。

eksctlコマンドを利用すれば比較的容易にEKSのプライベートクラスターが構築可能ですが([EKS Fully-Private Cluster](https://eksctl.io/usage/eks-private-cluster/)参照)、EKSクラスターが、どのようなAWSサービスを活用しているのか、どのようなIAM権限や、通信経路が必要になるのかを学習することも目的としているため、スクラッチで順を追って構築する手順にしています。

# 作成環境
![Overall Architecture](./Documents/overall_architecture.svg)

このハンズオンで、以下の環境を構築できます。
+ シンプルなEKSプライベートクラスター(ワーカーノードは、EC2タイプ)を用意し、シンプルなhttpdのpodを稼働させる
+ Autoscalerを導入し、ワーカーノードをスケールイン/アウトさせる。
+ AWS Load Balancer Controllerを導入し、ELBによるロードバランシングを実装する

EKSの構築の手順が複雑なため、手順の多くはCloudFormation化していますが、一部CLIで設定する箇所もあります。
またGUI(マネージメントコンソール)はUIが頻繁に変わるため、CloudFormationのスタック作成も含め全てAWS CLI(LinuxやMacのシェル環境を前提)での実行を前提としています。

# ハンズオン(その１): シンプルなEKSプライベートクラスター作成
シンプルなEKSプライベートクラスターを作成し、動作テストでpodを動かします。
![Simple EKS Private Cluster Architecture](./Documents/basic_arch.svg)
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
        --stack-name EksPoc-VpceSimple \
        --template-body "file://./src/vpce_simple.yaml" 
```

## (3)IAMロール&KMSキー作成
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
```
```shell
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

## (5)EKSコントロールプレーン&ノードグループ作成
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
#### (iii)高権限環境へのkubectlセットアップ
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
#### (iv) ソースコードのclone
```shell
sudo yum -y install git
git clone https://github.com/Noppy/EKSPoC_For_SecureEnvironment.git
cd EKSPoC_For_SecureEnvironment
```
### (5)-(b) EKSクラスター作成(k8sコントロールプレーン作成)
#### (i) EKSクラスター作成
EKSクラスター作成は15分程度かかります。
```shell
aws cloudformation create-stack \
        --stack-name EksPoc-EksControlPlane \
        --template-body "file://./src/eks_control_plane.yaml" 
```

#### (ii)高権限環境のkubectlをコントロールプレーンに接続
kubectlからクラスターが参照できるように設定を行います。
```shell
#KESクラスター情報取得
EKS_CLUSTER_NAME=$(aws --output text cloudformation \
    describe-stacks --stack-name EksPoc-EksControlPlane \
    --query 'Stacks[].Outputs[?OutputKey==`ClusterName`].[OutputValue]' )
echo "EKS_CLUSTER_NAME = ${EKS_CLUSTER_NAME}"
```
```shell
# kubectl用のconfig取得
aws eks update-kubeconfig --name ${EKS_CLUSTER_NAME}

#kubectlコマンドからのk8sマスターノード接続確認
kubectl get svc
```

### (5)-(c) EKSワーカーグループ作成
#### (i)aws-auth ConfigMapのクラスターへの適用
ワーカーノードに適用するインスタンスロールをk8sのコントロールプレーンで認識し有効化するために、`aws-auth`でマッピングを行います。
- [aws-auth設定の最新情報はこちらを参照](https://docs.aws.amazon.com/ja_jp/eks/latest/userguide/add-user-role.html#aws-auth-configmapg)

aws-auth ConfigMap が適用済みであるかどうかを確認します。
```shell

kubectl describe configmap -n kube-system aws-auth
```
`Error from server (NotFound): configmaps "aws-auth" not found`というエラーが表示された場合は、以下のステップを実行してストック ConfigMap を適用します。
```shell
curl -o aws-auth-cm.yaml https://amazon-eks.s3.us-west-2.amazonaws.com/cloudformation/2020-10-29/aws-auth-cm.yaml
```
CloudFormationからWorkerNodeインスタンス用のIAMロールのARNを取得します。
```shell
aws --output text cloudformation describe-stacks \
    --stack-name EksPoc-IAM \
    --query 'Stacks[].Outputs[?OutputKey==`EC2k8sWorkerRoleArn`].[OutputValue]'
```
aws-auth-cm.yaml編集 
`<ARN of instance role (not instance profile)>`をWorkerNodeのインスタンスロールARNに修正します。
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

```

#### (ii)ノードグループ作成前の情報取得
```shell
#WorkerへのSSH接続設定
KEY_NAME="CHANGE_KEY_PAIR_NAME" #SSH接続する場合
#KEY_NAME=""                    #SSH接続しない場合はブランクを設定する 

EKS_CLUSTER_NAME=$(aws --output text cloudformation \
    describe-stacks --stack-name EksPoc-EksControlPlane \
    --query 'Stacks[].Outputs[?OutputKey==`ClusterName`].[OutputValue]' )
EKS_B64_CLUSTER_CA=$(aws --output text cloudformation \
    describe-stacks --stack-name EksPoc-EksControlPlane \
    --query 'Stacks[].Outputs[?OutputKey==`CertificateAuthorityData`].[OutputValue]' )
EKS_API_SERVER_URL=$(aws --output text cloudformation \
    describe-stacks --stack-name EksPoc-EksControlPlane \
    --query 'Stacks[].Outputs[?OutputKey==`ControlPlaneEndpoint`].[OutputValue]' )
echo "
KEY_NAME           = ${KEY_NAME}
EKS_CLUSTER_NAME   = ${EKS_CLUSTER_NAME}
EKS_B64_CLUSTER_CA = ${EKS_B64_CLUSTER_CA}
EKS_API_SERVER_URL = ${EKS_API_SERVER_URL}
"

```
#### (iii)EKSノードグループ作成
```shell
CFN_STACK_PARAMETERS='
[
  {
    "ParameterKey": "ClusterName",
    "ParameterValue": "'"${EKS_CLUSTER_NAME}"'"
  },
  {
    "ParameterKey": "B64ClusterCa",
    "ParameterValue": "'"${EKS_B64_CLUSTER_CA}"'"
  },
  {
    "ParameterKey": "ApiServerUrl",
    "ParameterValue": "'"${EKS_API_SERVER_URL}"'"
  },  
  {
    "ParameterKey": "KeyName",
    "ParameterValue": "'"${KEY_NAME}"'"
  }
]'
aws cloudformation create-stack \
        --stack-name EksPoc-EksNodeGroup\
        --template-body "file://./src/eks_worker_nodegrp.yaml" \
        --parameters "${CFN_STACK_PARAMETERS}" ;

```

#### (iv) k8sでの状態確認
```shell
# WorkerNode状態確認
kubectl get nodes --watch
```


## (6) k8s RBAC設定: IAMユーザ/ロールの追加
`aws-auth`にk8sのRBAC認証に対応させたいIAMユーザ/ロールを追加します。
手順の概要は以下のとおりです。
- `kubectl`コマンドで`aws-auth ConfigMap`を開き編集する
- 設定は`mapRoles`にリスト形式で追加する。追加する場合の設定はそれぞれ以下の通り
    - `rolearn:`または`userarn`: IAMロールを追加する場合は`rolearn`、IAMユーザを追加する場合は`userarn`で、対象のARNを指定する。
    - `username`: kubernetes内のユーザー名
    - `groups` : k8s内でのマッピング先のグループをリストで指定する。
- エディタで保存&終了(viエディタなので、`:`のあと`wq`)すると反映してくれる。
- 参考情報
    - [EKSドキュメント](https://docs.aws.amazon.com/ja_jp/eks/latest/userguide/add-user-role.html#aws-auth-configmap)

### (6)-(a) kubectl実行用EC2のインスタンスロール登録
- 事前の情報取得
```shell
#kubectl実行用EC2のインスタンスロールのARN取得
KUBECTL_ROL_ARN=$(aws --output text cloudformation \
    describe-stacks --stack-name EksPoc-IAM \
    --query 'Stacks[].Outputs[?OutputKey==`EC2kubectlRoleArn`].[OutputValue]' )

echo "
KUBECTL_ROL_ARN = ${KUBECTL_ROL_ARN}"
```
- `aws-auth ConfigMap`の編集
```shell
#aws-auth ConfigMapを開く
kubectl edit -n kube-system configmap/aws-auth
```
```yaml
# Please edit the object below. Lines beginning with a '#' will be ignored,
# and an empty file will abort the edit. If an error occurs while saving this file will be
# reopened with the relevant failures.
#
apiVersion: v1
data:
  mapRoles: |
    -
      rolearn: arn:aws:iam::616605178605:role/EksPoc-IAM-EC2k8sWorkerRole-8BI00X63GF2P
      username: system:node:{{EC2PrivateDNSName}}
　    groups:
        - system:bootstrappers
        - system:nodes
<↓ココから下を追加>
    - 
      rolearn: "$KUBECTL_ROL_ARN のARN値を指定"
      username: kubectladmin
      groups:
        - system:masters
<ここまで>
<以下略>
```

### (6)-(b) 参照ユーザの追加
```shell
#aws-auth ConfigMapを開く
kubectl edit -n kube-system configmap/aws-auth
```
```yaml
# Please edit the object below. Lines beginning with a '#' will be ignored,
# and an empty file will abort the edit. If an error occurs while saving this file will be
# reopened with the relevant failures.
#
apiVersion: v1
data:
  mapRoles: |
    -
      rolearn: arn:aws:iam::616605178605:role/EksPoc-IAM-EC2k8sWorkerRole-8BI00X63GF2P
      username: system:node:{{EC2PrivateDNSName}}
　    groups:
        - system:bootstrappers
        - system:nodes
    - 
      rolearn: "$KUBECTL_ROL_ARN のARN値を指定"
      username: kubectladmin
      groups:
        - system:masters
<↓ココから下を追加>
    - 
      rolearn: "コンソール操作時の権限のARNを指定"
      username: consoleadmin
      groups:
        - system:masters
<ここまで>
<以下略>
```

## (7) 動作テスト(podの起動)
作成したEKSのkubernetes環境の動作確認のために事前にECRに登録したhttpdのDockerイメージを利用し以下のようなサービスを作成して、端末からアクセスできるかテストします。
![kubernetesのテスト環境](./Documents/k8s_simple_service_arch.svg)

参考情報
- [【Kubernetes】Serviceを作成してローカルPCからアクセスしてみる](https://amateur-engineer-blog.com/kubernetes-service/)

### (7)-(a) ECRリポジトリのURL取得
```shell
REPO_URL=$(aws --output text cloudformation \
    describe-stacks --stack-name EksPoc-Ecr \
    --query 'Stacks[].Outputs[?OutputKey==`EcrRepositoryUri`].[OutputValue]' )
echo "
REPO_URL = ${REPO_URL}
"
```
### (7)-(b) kubernetestのDeploymentとService作成
#### (i) 定義ファイルの準備
```shell
#Deployment定義ファイルの作成
#環境固有となるECRレポジトリURL情報をDeploymentに設定します。
sed -e "s;REPO_URL;${REPO_URL};" k8s_define/httpd-deployment.yaml.template > httpd-deployment.yaml
cat httpd-deployment.yaml

#Service定義ファイルの確認
cat k8s_define/httpd-service.yaml
```
#### (ii) DeploymentとServiceの適用
kubectlコマンドを利用して定義を適用します。
```shell
#Deploymentの適用
kubectl apply -f httpd-deployment.yaml

#Serviceの適用
kubectl apply -f k8s_define/httpd-service.yaml
```
#### (iii) 状態を確認します。
- Deploymentの状態確認
```shell
kubectl get deployments -o wide httpd-deployment

NAME               READY   UP-TO-DATE   AVAILABLE   AGE   CONTAINERS   IMAGES                                                                 SELECTOR
httpd-deployment   0/2     2            0           9s    httpd        141247782993.dkr.ecr.ap-northeast-1.amazonaws.com/ekspoc-repo:latest   app=httpd-pod
```
- Podの状態確認
```shell
kubectl get pods -o wide 

NAME                               READY   STATUS    RESTARTS   AGE     IP            NODE                                             NOMINATED NODE   READINESS GATES
httpd-deployment-65f68b9dfc-2bx8n   1/1     Running   0          29s   10.1.39.243    ip-10-1-42-54.ap-northeast-1.compute.internal     <none>           <none>
httpd-deployment-65f68b9dfc-9svlr   1/1     Running   0          29s   10.1.154.189   ip-10-1-147-247.ap-northeast-1.compute.internal   <none>           <none>
```
- Service状態確認
```shell
kubectl get svc -o wide httpd-service

NAME            TYPE        CLUSTER-IP       EXTERNAL-IP   PORT(S)    AGE     SELECTOR
httpd-service   ClusterIP   172.20.170.144   <none>        8080/TCP   9m31s   app=httpd-pod
```
#### (iv) クライアントからの接続確認
ClusterIPは、通常kubernetesのクラスター内からのみからのアクセスとなりますが、kubectlコマンドでフォワードさせることでクラスター外の端末からアクセスが可能となります。
- ポートフォワーディング起動(この状態でwaitになります。終了する場合は`CTRL+C`で終了)
```shell
kubectl port-forward service/httpd-service 9999:8080
Forwarding from 127.0.0.1:9999 -> 80
Forwarding from [::1]:9999 -> 80
```
- 別端末から`kubectl port-forward`を実行しているOS上にログインします
- 別端末で下記コマンドでhttpサーバの情報が参照できたら成功です
```shell
curl http://localhost:9999

<html>
  <head>
    <title>PHP Sample</title>
  </head>
  <body>
    httpd-deployment-dbb8b7f8c-nbkg2  </body>
</html>
```

### (7)-(c) ServiceとDeploymentの削除
```shell
#Serviceの削除
kubectl delete -f k8s_define/httpd-service.yaml

#Deploymentの削除
kubectl delete -f httpd-deployment.yaml
```

# ハンズオン(その2): ClusterAutoscalerを追加しk8sでスケールイン／アウトをコントロールする
以下の作業は、Bastion兼高権限用インスタンスで作業します。
作業のカレントディレクトリは、githubからcloneしたEKSPoC_For_SecureEnvironmentのリポジトリ直下を前提としています。
![Add Autoscaler Architecture](./Documents/arch-add_Autoscaler.svg)

## (1) OIDCプロバイダ
### (1)-(a) jqのインストール
コマンドの中でJSONデータを処理するjqコマンドを利用するため、予めjqをインストールします。
```shell
sudo yum -y install jq
```
### (1)-(b) VPCエンドポイント作成
OIDCの認証情報取得のためにstsへのアクセスを行うため、STSのVPCエンドポイントを追加します。
```shell
 aws cloudformation create-stack \
        --stack-name EksPoc-Vpce-oidc \
        --template-body "file://./src/vpce_for_oidc.yaml"
```
### (1)-(c) OIDCプロバイダのサムプリント取得
サムプリントは、証明書の暗号化ハッシュです。
- 参考情報
    - [EKSユーザーガイド: OIDCプロバイダ作成](https://docs.aws.amazon.com/ja_jp/eks/latest/userguide/enable-iam-roles-for-service-accounts.html)
    - [IAMユーザーガイド: OIDCプロバイダ作成](https://docs.aws.amazon.com/ja_jp/IAM/latest/UserGuide/id_roles_providers_create_oidc.html#manage-oidc-provider-cli)
    - [IAMユーザーガイド: サムプリント取得](https://docs.aws.amazon.com/ja_jp/IAM/latest/UserGuide/id_roles_providers_create_oidc_verify-thumbprint.html)
    - [Terraformでeksのiam role per podを実現する](https://medium.com/@sueken0117/terraform%E3%81%A7eks%E3%81%AEiam-role-per-pod%E3%82%92%E5%AE%9F%E7%8F%BE%E3%81%99%E3%82%8B-5b9b1a95eeb9)


#### (i) EKSクラスターからOICD用のURLを取得(CloudFormationのスタック出力結果からの取得)
```shell
OpenIdConnectIssuerUrl=$(aws --output text \
    cloudformation describe-stacks \
        --stack-name EksPoc-EksControlPlane \
        --query 'Stacks[].Outputs[?OutputKey==`OpenIdConnectIssuerUrl`].[OutputValue]' )
```
#### (ii) OICDプロバイダーのから証明書を取得
```shell
# IdP の設定ドキュメント取得のURL生成
URL="${OpenIdConnectIssuerUrl}/.well-known/openid-configuration"
echo $URL

#ドメイン取得
FQDN=$(curl $URL 2>/dev/null | jq -r '.jwks_uri' | sed -E 's/^.*(http|https):\/\/([^/]+).*/\2/g')
echo $FQDN

#サーバー証明書の取得
 echo | openssl s_client -connect $FQDN:443 -servername $FQDN -showcerts 
```
opensslコマンドを実行すると、次のような証明書が複数表示されます。
複数の証明書のうち表示される最後 (コマンド出力の最後) の証明書を特定します。
```
-----BEGIN CERTIFICATE-----
 MIICiTCCAfICCQD6m7oRw0uXOjANBgkqhkiG9w0BAQUFADCBiDELMAkGA1UEBhMC
 VVMxCzAJBgNVBAgTAldBMRAwDgYDVQQHEwdTZWF0dGxlMQ8wDQYDVQQKEwZBbWF6
 b24xFDASBgNVBAsTC0lBTSBDb25zb2xlMRIwEAYDVQQDEwlUZXN0Q2lsYWMxHzAd
 BgkqhkiG9w0BCQEWEG5vb25lQGFtYXpvbi5jb20wHhcNMTEwNDI1MjA0NTIxWhcN
 MTIwNDI0MjA0NTIxWjCBiDELMAkGA1UEBhMCVVMxCzAJBgNVBAgTAldBMRAwDgYD
 VQQHEwdTZWF0dGxlMQ8wDQYDVQQKEwZBbWF6b24xFDASBgNVBAsTC0lBTSBDb25z
 b2xlMRIwEAYDVQQDEwlUZXN0Q2lsYWMxHzAdBgkqhkiG9w0BCQEWEG5vb25lQGFt
 YXpvbi5jb20wgZ8wDQYJKoZIhvcNAQEBBQADgY0AMIGJAoGBAMaK0dn+a4GmWIWJ
 21uUSfwfEvySWtC2XADZ4nB+BLYgVIk60CpiwsZ3G93vUEIO3IyNoH/f0wYK8m9T
 rDHudUZg3qX4waLG5M43q7Wgc/MbQITxOUSQv7c7ugFFDzQGBzZswY6786m86gpE
 Ibb3OhjZnzcvQAaRHhdlQWIMm2nrAgMBAAEwDQYJKoZIhvcNAQEFBQADgYEAtCu4
 nUhVVxYUntneD9+h8Mg9q6q+auNKyExzyLwaxlAoo7TJHidbtS4J5iNmZgXL0Fkb
 FFBjvSfpJIlJ00zbhNYS5f6GuoEDmFJl0ZxBHjJnyp378OD8uTs7fLvjx79LjSTb
 NYiytVbZPQUQ5Yaxu2jXnimvw3rrszlaEXAMPLE=
 -----END CERTIFICATE-----
```
 証明書 (`-----BEGIN CERTIFICATE-----` および `-----END CERTIFICATE-----` 行を含む) をコピーして、テキストファイルに貼り付けます。次に、`certificate.crt` という名前でファイルを保存します。
```shell
cat > certificate.crt
コピーした証明書を貼り付けて、最後にCTRL+Dで終了する

#ファイルの確認
cat certificate.crt
```

#### (iii) サムプリントの取得
```shell
THUMBPRINT=$(openssl x509 -in certificate.crt -fingerprint -noout | sed -E 's/SHA1 Fingerprint=(.*)/\1/g' | sed -E 's/://g')
echo $THUMBPRINT
```
### (1)-(d) OIDCプロバイダ作成
```shell
aws iam create-open-id-connect-provider \
    --url "${OpenIdConnectIssuerUrl}" \
    --thumbprint-list "${THUMBPRINT}" \
    --client-id-list "sts.amazonaws.com"

```

## (2) Cluster Autoscalerのセットアップ
Cluster Autoscalerを導入して、kubernetesからAutoScalingを調整してスケールアップ/スケールインをコントローするようにします。
- 参考情報
    - [Kubernetes Autoscaler](https://github.com/kubernetes/autoscaler)
        - [EKSでのセットアップ手順](https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/cloudprovider/aws/README.md)
        - [AWS OIDCプロバイダー利用時の説明](https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/cloudprovider/aws/CA_with_AWS_IAM_OIDC.md)

### (2)-(a) Cluster Autoscaler用にVPCエンドポイントを追加
Cluster Autoscalerは、ワーカーノードのリソース利用状況に合わせて、EC2 Autoscalingのインスタンス数設定を変更することで、キャパシティーの調整を行います。
Cluster AutoscalerからEC2 Autoscalingを操作できるようにするために、EC2 AutoscalingのVPCエンドポイントを追加します。
```shell
 aws cloudformation create-stack \
        --stack-name EksPoc-Vpce-Autoscaler \
        --template-body "file://./src/vpce_for_autoscaler.yaml"
```

### (2)-(b) AutoscalerのdockerイメージをECRに格納
本検証環境は、kubernetesのワーカーノードから外部にはアクセスができないため、そのままではCluster Autoscalerのdocerイメージが取得できません。
そのためECRリポジトリを用意し、Cluster Autoscalerのdocerイメージを格納しておきます。
#### (i) Autoscalerイメージ保管用ECRリポジトリ作成
```shell
aws cloudformation create-stack \
        --stack-name EksPoc-AutoscalerEcr \
        --template-body "file://./src/Autoscaler/ecr_for_autoscaler.yaml" 
```

#### (ii) (Dockerインスタンス)Autoscalerイメージの取得と保管
以下の作業は、別端末を開いてDockerインスタンスにログインして作業します。
- Dockerインスタンスへのログイン
```shell
export PROFILE=<PoC環境のAdmministratorAccess権限が実行可能なプロファイル>
export REGION="ap-northeast-1"

#プロファイルの動作テスト
#COMPUTE_PROFILE
aws --profile ${PROFILE} sts get-caller-identity
```
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

- ec2-userへの変更
```shell
sudo -u ec2-user -i
```

- dockerイメージの情報取得
下記で表示されるイメージ情報のURI(`k8s.gcr.io/autoscaling/cluster-autoscaler`など)を控えておきます。
```shell
curl https://raw.githubusercontent.com/kubernetes/autoscaler/master/cluster-autoscaler/cloudprovider/aws/examples/cluster-autoscaler-autodiscover.yaml 2> /dev/null | grep 'image:'
```
タグ情報は、ウェブブラウザで、GitHub の [Cluster Autoscaler リリースページ](https://github.com/kubernetes/autoscaler/releases)を開き、最新の (クラスターの Kubernetes のメジャーおよびマイナーバージョンに一致する) Cluster Autoscaler バージョンを見つけます。ととえば、クラスターの Kubernetes バージョンが 1.21 の場合、1.21 で始まる Cluster Autoscaler リリースを見つけます。次のステップで使用するので、そのリリースのセマンティックバージョン番号 (1.21.n) を書き留めておきます。


上記のimage情報を変数に入れておきます。
```shell
AUTOSCALER_PATH="<上記で控えておいたAutoscalerのイメージのuri:タグ情報>"
```
AutoscalerのDockerイメージをローカルにpullします。
```shell
docker pull "${AUTOSCALER_PATH}"
```
```shell
#取得した情報の確認
docker images
```
- dockerイメージをECRに格納
Autoscaler用ECRのURI取得
```shell
REPO_URL=$( aws --output text \
    ecr describe-repositories \
        --repository-names autoscaler-repo \
    --query 'repositories[].repositoryUri' ) ;
echo "
REPO_URL = ${REPO_URL}
"
```
ECRへのpush
```shell
# ECR登録用のタグを作成
docker tag ${AUTOSCALER_PATH} ${REPO_URL}:latest
docker images #作成したtagが表示されていることを確認

#ECRログイン
#"Login Succeeded"と表示されることを確認
aws ecr get-login-password | docker login --username AWS --password-stdin ${REPO_URL}

#イメージのpush
docker push ${REPO_URL}:latest

#ECR上のレポジトリ確認
aws ecr list-images --repository-name autoscaler-repo
```
### (iii)ログアウト
作業が完了したので、Dockerインスタンスからログアウトします
```shell
exit
exit
```

以後の作業は、Bastion兼高権限用インスタンスに戻って行います。

### (2)-(c) Cluster Autoscaler用IAMロール追加
#### (i)IAMロールの信頼関係(Trust relationship)設定用の情報取得
```shell
#EKSクラスターのOIDC情報取得
OIDC_FQDN=$(aws --output text \
    cloudformation describe-stacks \
        --stack-name EksPoc-EksControlPlane \
        --query 'Stacks[].Outputs[?OutputKey==`OpenIdConnectIssuerUrl`].[OutputValue]' | sed -E 's/^.*(http|https):\/\/([^/]+).*/\2/g')
echo "OIDC_FQDN = ${OIDC_FQDN}"

#該当OIDCプロバイダーのARN取得
OIDCProviderARN=$(aws --output text iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn' | grep $OIDC_FQDN)
echo "OIDCProviderARN = ${OIDCProviderARN}"

#該当OIDCプロバイダーのURI取得
OIDCProviderURI=$(aws --output text iam get-open-id-connect-provider --open-id-connect-provider-arn ${OIDCProviderARN} --query 'Url')
echo "OIDCProviderURI = ${OIDCProviderURI}"
```
#### (ii)IAMロールの信頼関係用ポリシー生成
```shell
sed -e "s;OIDCProviderARN;${OIDCProviderARN};g" \
    -e "s;OIDCProviderURI;${OIDCProviderURI};g" \
    src/Autoscaler/cluster_autoscaler_iam_role_trust_policy.json_template > cluster_autoscaler_iam_role_trust_policy.json
```
#### (iii)Cluster Autoscaler用のIAMロール作成
```shell
#KESクラスター情報取得
EKS_CLUSTER_NAME=$(aws --output text cloudformation \
    describe-stacks --stack-name EksPoc-EksControlPlane \
    --query 'Stacks[].Outputs[?OutputKey==`ClusterName`].[OutputValue]' )
echo "EKS_CLUSTER_NAME = ${EKS_CLUSTER_NAME}"

IAM_ROLE_NAME=${EKS_CLUSTER_NAME}-Autoscaler_Role
```
```shell
#IAMロール作成
aws iam create-role \
    --role-name "${IAM_ROLE_NAME}" \
    --assume-role-policy-document "file://cluster_autoscaler_iam_role_trust_policy.json"

#IAMポリシー(インラインポリシー)のアタッチ
aws iam put-role-policy \
    --role-name "${IAM_ROLE_NAME}" \
    --policy-name Autoscaler \
    --policy-document "file://src/Autoscaler/cluster_autoscaler_iam_policy.json"
```
### (2)-(d) ワーカーノードのインスタンスロールへの権限付与
下記ドキュメントに`Attach the above created policy to the instance role that's attached to your Amazon EKS worker nodes.`とあるので、同じIAMポリシーをワーカーノードのインスタンスロールにも付与します。
- https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/cloudprovider/aws/CA_with_AWS_IAM_OIDC.md

```shell
#ワーカーノードのインスタンスロールのロール名を取得
WORKER_ROLE_NAME=$(aws --output text cloudformation \
    describe-stacks --stack-name EksPoc-IAM \
    --query 'Stacks[].Outputs[?OutputKey==`EC2k8sWorkerRoleName`].[OutputValue]' )
echo "WORKER_ROLE_NAME = ${WORKER_ROLE_NAME}"
```
```shell
#IAMポリシー(インラインポリシー)のアタッチ
aws iam put-role-policy \
    --role-name "${WORKER_ROLE_NAME}" \
    --policy-name Autoscaler \
    --policy-document "file://src/Autoscaler/cluster_autoscaler_iam_policy.json"
```

### (2)-(e) Autoscalerの定義サンプル取得と編集
#### (ii) ロールのARN確認
```shell
#ロールのARNをメモ帳などに控えておきます。
aws --output text iam get-role --role-name "${IAM_ROLE_NAME}" --query 'Role.Arn'
```

#### (i) AutoscalerのGitHubから定義ファイルを取得
```shell
curl -o cluster-autoscaler-autodiscover.yaml https://raw.githubusercontent.com/kubernetes/autoscaler/master/cluster-autoscaler/cloudprovider/aws/examples/cluster-autoscaler-autodiscover.yaml
```

#### (ii) 定義ファイルの変更
エディタで開いて定義ファイルを編集します。
- クラスター名の変更
    - `<YOUR CLUSTER NAME>`の部分を実際のEKSクラスター名に変更します。
    - `k8s.gcr.io/autoscaling/cluster-autoscaler:v1.21.0`の部分を、(2)-(b)で保管したECRに変更します。URIは(2)-(b)で取得したものでタグは`latest`にします
        - 変更後のimageパスの例: `999999999999.dkr.ecr.ap-northeast-1.amazonaws.com/autoscaler-repo:latest`
    - 起動オプションの変更
        - `--aws-use-static-instance-list=true`を追加。(デフォルトではEC2インスタンスの最新リスト取得のために`api.pricing.us-east-1.amazonaws.com`にアクセスするが、インターネット接続がない環境ではエラーになりAutoscalerが起動失敗するため無効化する)
```yaml
      serviceAccountName: cluster-autoscaler
      containers:
        - image: k8s.gcr.io/autoscaling/cluster-autoscaler:v1.21.0  <<== 変更する
          name: cluster-autoscaler
          resources:
            limits:
              cpu: 100m
              memory: 600Mi
            requests:
              cpu: 100m
              memory: 600Mi
          command:
            - ./cluster-autoscaler
            - --v=4
            - --stderrthreshold=info
            - --cloud-provider=aws
            - --skip-nodes-with-local-storage=false
            - --expander=least-waste
            - --node-group-auto-discovery=asg:tag=k8s.io/cluster-autoscaler/enabled,k8s.io/cluster-autoscaler/<YOUR CLUSTER NAME> <<== 変更する
            - --aws-use-static-instance-list=true <<==追加する
```
- Autoscaler用IAMロールの追加
    - Autoscalerで利用するOIDC認証を行うIAMロールを定義に追加します
    - 追加場所と追加方法は、定義ファイル先頭の`metadata`セクションに`annotations`で追加します。
    - `arn:aws:iam::xxxxx:role/Amazon_CA_role`の部分を、(2)-(b)の(iii)で作成したIAMロールのARNに置き換えます。
```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  labels:
    k8s-addon: cluster-autoscaler.addons.k8s.io
    k8s-app: cluster-autoscaler
  annotations:   <==行追加
    eks.amazonaws.com/role-arn: arn:aws:iam::xxxxx:role/Amazon_CA_role   # Add the IAM role created in the above C section.  <==行追加
  name: cluster-autoscaler
  namespace: kube-system
```
### (2)-(f) Autoscalerの適用
#### (i) Autoscalerの適用
```shell
kubectl apply -f cluster-autoscaler-autodiscover.yaml
```
#### (ii) 状態確認
```shell
kubectl get deployment/cluster-autoscaler -o wide -n kube-system


NAME                 READY   UP-TO-DATE   AVAILABLE   AGE   CONTAINERS           IMAGES                                                                     SELECTOR
cluster-autoscaler   1/1     1            1           16s   cluster-autoscaler   616605178605.dkr.ecr.ap-northeast-1.amazonaws.com/autoscaler-repo:latest   app=cluster-autoscaler
```
`READY`が`1/1`になり、AVAILABLEが`1`であれば成功です。

- ログを参照する場合は下記コマンドで確認できます。
```shell
kubectl -n kube-system logs -f deployment.apps/cluster-autoscaler
```


### (2)-(f) Autoscalerの検証
`ハンズオン(その1)`の（7）で動作確認で利用したdeploymentを利用して、autoscalingの動作確認を行います。

#### (i)pod数の変更
`httpd-deployment.yaml`の`replicas:`の数を`2`から`20`に変更します。
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: httpd-deployment
  labels:
    app: httpd-dep
spec:
  replicas: 2 <<= ここを2から20に変更する
  selector:
    matchLabels:
      app: httpd-pod
<以下略>
```
#### (ii)適用
```shell
kubectl apply -f httpd-deployment.yaml
```
#### (iii)確認
```shell
# deploymentの状態確認
kubectl get deployments httpd-deployment

#ワーカーノードの確認
kubectl get nodes
```
また、Autoscalingの`Desired capacity`が変更されているかを確認する。

# ハンズオン(その3): AWS Load Balancer ControllerによるELB構成
![Add AWS Load Balancer Controller](./Documents/arch-add_elb.svg)
- 参考情報
    - [EKSユーザーガイド: AWS Load Balancer Controller アドオンのインストール](https://docs.aws.amazon.com/ja_jp/eks/latest/userguide/aws-load-balancer-controller.html)

## (1) PrivateクラスターのためのVPCE作成とECRイメージの格納
### (1)-(a) AWS Load Balancer Controller用にVPCエンドポイントを追加
AWS Load Balancer Controllerから、ELBを操作できるようにするために、Elastic LoadbalancerのVPCエンドポイントを追加します。
```shell
 aws cloudformation create-stack \
        --stack-name EksPoc-Vpce-AwsLoadBalancerController \
        --template-body "file://./src/vpce_for_aws-load-balancer-controller.yaml"
```

### (1)-(b) AWS Load Balancer ControllerとCert-ManagerのDockerイメージの保管
本検証環境はkubernetesのワーカーノードから外部にはアクセスができないため、ECRリポジトリを用意しAWS Load Balancer Controllerのdocerイメージを格納しておきます。
#### (i) ECRリポジトリ作成
- AWS Load Balancer Controller
```shell
aws cloudformation create-stack \
        --stack-name EksPoc-AwsLoadBalancerControllerEcr \
        --template-body "file://./src/AWSLoadBalancerController/ecr_for_aws-load-balancer-controller.yaml"
```
- CERT-Manager
```shell
aws cloudformation create-stack \
        --stack-name EksPoc-CertManagerControllerEcr \
        --template-body "file://./src/AWSLoadBalancerController/ecr_for_cert-manager-controller.yaml"
```
```shell
aws cloudformation create-stack \
        --stack-name EksPoc-CertManagerCainjectorEcr \
        --template-body "file://./src/AWSLoadBalancerController/ecr_for_cert-manager-cainjector.yaml"
```
```shell
aws cloudformation create-stack \
        --stack-name EksPoc-CertManagerWebhookEcr \
        --template-body "file://./src/AWSLoadBalancerController/ecr_for_cert-manager-webhook.yaml"
```

#### (ii) AWS Load Balancer Controllerの最新バージョンを確認
下記AWS Load Balancer ControllerのGitHubのリリース情報から、最新バージョンを確認する。
https://github.com/kubernetes-sigs/aws-load-balancer-controller/releases

最新バージョンを確認したら下記情報を控えておく
- バージョン名: 例えば`v.2.4.1`など
- Assetsの定義ファイルのURI: Assetsのリストでファイル名が`v2_4_1_full.yaml`などとあるYAML定義のURLを控える
- DockerイメージのURI: リリース情報の冒頭に`Image: docker.io/amazon/aws-alb-ingress-controller:v2.4.1`という形で表示されているのでそこから取得するか、上記のYAML定義の中から情報を取得する。

#### (iii) (Dockerインスタンス)AWS Load Balancer Controllerイメージの取得と保管

以下の作業は、別端末を開いてDockerインスタンスにログインして作業します。
- Dockerインスタンスへのログイン
```shell
export PROFILE=<PoC環境のAdmministratorAccess権限が実行可能なプロファイル>
export REGION="ap-northeast-1"

#プロファイルの動作テスト
#COMPUTE_PROFILE
aws --profile ${PROFILE} sts get-caller-identity
```
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

- ec2-userへの変更
```shell
sudo -u ec2-user -i
```

- DockerイメージのPull
```shell
AWSLBCTL_PATH="<(ii)で控えておいたAWS Load Balancer Controllerのイメージのuri:タグ情報>"
```
AWS Load Balancer ControllerのDockerイメージをローカルにpullします。
```shell
docker pull "${AWSLBCTL_PATH}"
```
```shell
#取得した情報の確認
docker images
```
- dockerイメージをECRに格納
AWS Load Balancer Controller用ECRのURI取得
```shell
REPO_URL=$( aws --output text \
    ecr describe-repositories \
        --repository-names aws-load-balancer-controller-repo \
    --query 'repositories[].repositoryUri' ) ;
echo "
REPO_URL = ${REPO_URL}
"
```
ECRへのpush
```shell
# ECR登録用のタグを作成
docker tag ${AWSLBCTL_PATH} ${REPO_URL}:latest
docker images #作成したtagが表示されていることを確認

#ECRログイン
#"Login Succeeded"と表示されることを確認
aws ecr get-login-password | docker login --username AWS --password-stdin ${REPO_URL}

#イメージのpush
docker push ${REPO_URL}:latest

#ECR上のレポジトリ確認
aws ecr list-images --repository-name autoscaler-repo
```

#### (iv) (Dockerインスタンス)CertManagerイメージの取得と保管
同様にCertManagerのイメージをECRに保管します。最新情報は以下のデプロイ手順のCERT-Managerの`ノードが quay.io コンテナレジストリにアクセスできない場合`の説明を参照下さい。
- https://docs.aws.amazon.com/ja_jp/eks/latest/userguide/aws-load-balancer-controller.html


- マニフェストのダウンロード
```shell
curl -Lo cert-manager.yaml https://github.com/jetstack/cert-manager/releases/download/v1.5.4/cert-manager.yaml
```

- イメージURIの取得
```shell
grep -e 'image:' cert-manager.yaml

          image: "quay.io/jetstack/cert-manager-cainjector:v1.5.4"
          image: "quay.io/jetstack/cert-manager-controller:v1.5.4"
          image: "quay.io/jetstack/cert-manager-webhook:v1.5.4"
```
手動で以下を設定します
```shell
CERT_MGR_CAIN="<cert-manager-cainjectorのパスを設定>"
CERT_MGR_CONT="<cert-manager-controllerのパスを設定>"
CERT_MGR_WEBH="<quay.io/jetstack/cert-manager-webhook:のパスを設定>"
```

- ECRレポジトリのURI取得
```shell
CERT_MGR_CAIN_REPO_URL=$( aws --output text \
    ecr describe-repositories \
        --repository-names cert-manager-cainjector-repo \
    --query 'repositories[].repositoryUri' ) ;
CERT_MGR_CONT_REPO_URL=$( aws --output text \
    ecr describe-repositories \
        --repository-names cert-manager-controller-repo \
    --query 'repositories[].repositoryUri' ) ;
CERT_MGR_WEBH_REPO_URL=$( aws --output text \
    ecr describe-repositories \
        --repository-names cert-manager-webhook-repo \
    --query 'repositories[].repositoryUri' ) ;

echo "
CERT_MGR_CAIN_REPO_URL = ${CERT_MGR_CAIN_REPO_URL}
CERT_MGR_CONT_REPO_URL = ${CERT_MGR_CONT_REPO_URL}
CERT_MGR_WEBH_REPO_URL = ${CERT_MGR_WEBH_REPO_URL}
"
```
- イメージPull
```shell
docker pull "${CERT_MGR_CAIN}"
docker pull "${CERT_MGR_CONT}"
docker pull "${CERT_MGR_WEBH}"
```
確認します。
```shell
docker images
```
- ECRへのPush(cert-manager-cainjector)
```shell
docker tag ${CERT_MGR_CAIN} ${CERT_MGR_CAIN_REPO_URL}:latest
aws ecr get-login-password | docker login --username AWS --password-stdin ${CERT_MGR_CAIN_REPO_URL}
docker push ${CERT_MGR_CAIN_REPO_URL}:latest
aws ecr list-images --repository-name cert-manager-cainjector-repo
```

- ECRへのPush(cert-manager-controller)
```shell
docker tag ${CERT_MGR_CONT} ${CERT_MGR_CONT_REPO_URL}:latest
aws ecr get-login-password | docker login --username AWS --password-stdin ${CERT_MGR_CONT_REPO_URL}
docker push ${CERT_MGR_CONT_REPO_URL}:latest
aws ecr list-images --repository-name cert-manager-controller-repo 
```

- ECRへのPush(cert-manager-webhook)
```shell
docker tag ${CERT_MGR_WEBH} ${CERT_MGR_WEBH_REPO_URL}:latest
aws ecr get-login-password | docker login --username AWS --password-stdin ${CERT_MGR_WEBH_REPO_URL}
docker push ${CERT_MGR_WEBH_REPO_URL}:latest
aws ecr list-images --repository-name cert-manager-webhook-repo
```

### (v)ログアウト
作業が完了したので、Dockerインスタンスからログアウトします
```shell
exit
exit
```

## (2) AWS Load Balancer Controller用のIAMロール作成
以後の作業は、Bastion兼高権限用インスタンスに戻って行います。

### (2)-(a) IAMポリシー取得
```shell
curl -o iam_policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.4.0/docs/install/iam_policy.json
```

### (2)-(b) IAMロールの信頼関係(Trust relationship)設定用の情報取得
```shell
#EKSクラスターのOIDC情報取得
OIDC_FQDN=$(aws --output text \
    cloudformation describe-stacks \
        --stack-name EksPoc-EksControlPlane \
        --query 'Stacks[].Outputs[?OutputKey==`OpenIdConnectIssuerUrl`].[OutputValue]' | sed -E 's/^.*(http|https):\/\/([^/]+).*/\2/g')
echo "OIDC_FQDN = ${OIDC_FQDN}"

#該当OIDCプロバイダーのARN取得
OIDCProviderARN=$(aws --output text iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn' | grep $OIDC_FQDN)
echo "OIDCProviderARN = ${OIDCProviderARN}"

#該当OIDCプロバイダーのURI取得
OIDCProviderURI=$(aws --output text iam get-open-id-connect-provider --open-id-connect-provider-arn ${OIDCProviderARN} --query 'Url')
echo "OIDCProviderURI = ${OIDCProviderURI}"
```
### (2)-(c) IAMロールの信頼関係用ポリシー生成
```shell
sed -e "s;OIDCProviderARN;${OIDCProviderARN};g" \
    -e "s;OIDCProviderURI;${OIDCProviderURI};g" \
    src/AWSLoadBalancerController/aws-load-balancer-controller_iam_role_trust_policy.json_template > aws-load-balancer-controller_iam_role_trust_policy.json
```
生成した信頼関係用ポリシーの確認をします。
```shell
cat aws-load-balancer-controller_iam_role_trust_policy.json
```

### (2)-(d) IAMロールの作成
IAMロール名を設定します。
```shell
#KESクラスター情報取得
EKS_CLUSTER_NAME=$(aws --output text cloudformation \
    describe-stacks --stack-name EksPoc-EksControlPlane \
    --query 'Stacks[].Outputs[?OutputKey==`ClusterName`].[OutputValue]' )
echo "EKS_CLUSTER_NAME = ${EKS_CLUSTER_NAME}"

LB_CTL_IAM_ROLE_NAME=${EKS_CLUSTER_NAME}-AWS-Loadbalancer-Controler-Role
```
IAMロールを作成します。
```shell
#IAMロール作成
aws iam create-role \
    --role-name "${LB_CTL_IAM_ROLE_NAME}" \
    --assume-role-policy-document "file://aws-load-balancer-controller_iam_role_trust_policy.json"

#IAMポリシー(インラインポリシー)のアタッチ
aws iam put-role-policy \
    --role-name "${LB_CTL_IAM_ROLE_NAME}" \
    --policy-name loadbalancer \
    --policy-document "file://iam_policy.json"
```

### (2)-(e)  AWS Load Balancer Controller用のIAMロールをk8sにサービスアカウントとして登録
#### (i) 作成したIAMロールのARN取得
```shell
AWS_LOAD_BALANCER_CONTROLLER_IAM_ROLL_ARN=$(aws --output text \
    iam get-role --role-name "${LB_CTL_IAM_ROLE_NAME}" --query 'Role.Arn')

echo "
AWS_LOAD_BALANCER_CONTROLLER_IAM_ROLL_ARN = ${AWS_LOAD_BALANCER_CONTROLLER_IAM_ROLL_ARN}
"
```
#### (ii) k8sのサービスアカウント定義ファイルの作成
テンプレートにIAMロールのARNを設定します。
```shell
sed -e "s;AmazonEKSLoadBalancerControllerRoleARN;${AWS_LOAD_BALANCER_CONTROLLER_IAM_ROLL_ARN};g" \
    src/AWSLoadBalancerController/aws-load-balancer-controller-service-account.yaml_template > aws-load-balancer-controller-service-account.yaml

#確認します
cat aws-load-balancer-controller-service-account.yaml

```
#### (iii) k8sのクラスターへの登録
```shell
kubectl apply -f aws-load-balancer-controller-service-account.yaml
```
下記コマンドで登録されていることを確認します。
```shell
kubectl -n kube-system get serviceaccount aws-load-balancer-controller

NAME                           SECRETS   AGE
aws-load-balancer-controller   1         74s
```
## (3)CERT-Managerのインストール
### (i)マニフェストの取得
```shell
curl -Lo cert-manager.yaml https://github.com/jetstack/cert-manager/releases/download/v1.5.4/cert-manager.yaml
```

### (ii)マニフェストの編集
ダウンロードしたマニフェストのDockerイメージのURI(下記部分)をECRに格納したイメージのURIへ書き換えます。
```yaml
    image: "quay.io/jetstack/cert-manager-cainjector:v1.5.4"
    image: "quay.io/jetstack/cert-manager-controller:v1.5.4"
    image: "quay.io/jetstack/cert-manager-webhook:v1.5.4"
```
- ECRレポジトリのURI取得
取得したURIをメモ帳などに控えておきます。
```shell
CERT_MGR_CAIN_REPO_URL=$(aws --output text cloudformation describe-stacks \
        --stack-name EksPoc-CertManagerCainjectorEcr \
        --query 'Stacks[].Outputs[?OutputKey==`EcrRepositoryUri`].[OutputValue]')
CERT_MGR_CONT_REPO_URL=$(aws --output text cloudformation describe-stacks \
        --stack-name EksPoc-CertManagerControllerEcr \
        --query 'Stacks[].Outputs[?OutputKey==`EcrRepositoryUri`].[OutputValue]')
CERT_MGR_WEBH_REPO_URL=$(aws --output text cloudformation describe-stacks \
        --stack-name EksPoc-CertManagerWebhookEcr \
        --query 'Stacks[].Outputs[?OutputKey==`EcrRepositoryUri`].[OutputValue]')

echo "
CERT_MGR_CAIN_REPO_URL = ${CERT_MGR_CAIN_REPO_URL}
CERT_MGR_CONT_REPO_URL = ${CERT_MGR_CONT_REPO_URL}
CERT_MGR_WEBH_REPO_URL = ${CERT_MGR_WEBH_REPO_URL}
"
```

- マニフェストの編集
Dockerイメージを指定している3箇所(`image: "quay.io/jetstack/cert-manager-xxxxxx`部分)をECRに格納したイメージの`URI:latest`に変更する。
```shell
 vi cert-manager.yaml
```
編集後の`image:`部分の例。
```yaml
    image: "999999999999.dkr.ecr.ap-northeast-1.amazonaws.com/cert-manager-cainjector-repo:latest"
    image: "999999999999.dkr.ecr.ap-northeast-1.amazonaws.com/cert-manager-controller-repo:latest"
    image: "999999999999.dkr.ecr.ap-northeast-1.amazonaws.com/cert-manager-webhook-repo:latest"
```

### (iii)マニフェストの適用
```shell
kubectl apply \
    --validate=false \
    -f ./cert-manager.yaml

```
状態を確認します。READYが`1/1`ならpodが正常に起動しておりOKです。
```shell
kubectl -n cert-manager get deployments

NAME                      READY   UP-TO-DATE   AVAILABLE   AGE
cert-manager              1/1     1            1           55s
cert-manager-cainjector   1/1     1            1           55s
cert-manager-webhook      1/1     1            1           55s
```

## (4) AWS Load Balancer Controllerのインストール
### (4)-(a) Controllerのマニフェスト取得
(1)-(b)で確認したAWS Load Balancer ControllerバージョンのYAML定義ファイルを取得します。
```shell
# v2_4_0_full.yamlの場合
curl -Lo v2_4_0_full.yaml https://github.com/kubernetes-sigs/aws-load-balancer-controller/releases/download/v2.4.0/v2_4_0_full.yaml
```
### Controllerのマニフェストの編集


- Cluster
- image変更
- arg変更

#### (i)情報の取得
取得したクラスター名とLoadBalancerのECRのURIを控えておきます。
```shell
#KESクラスター情報取得
EKS_CLUSTER_NAME=$(aws --output text cloudformation \
    describe-stacks --stack-name EksPoc-EksControlPlane \
    --query 'Stacks[].Outputs[?OutputKey==`ClusterName`].[OutputValue]' )

LBCTL_REPO_URL=$(aws --output text cloudformation describe-stacks \
        --stack-name EksPoc-AwsLoadBalancerControllerEcr \
        --query 'Stacks[].Outputs[?OutputKey==`EcrRepositoryUri`].[OutputValue]')

VPCID=$(aws --output text cloudformation describe-stacks \
        --stack-name EksPoc-VPC \
        --query 'Stacks[].Outputs[?OutputKey==`VpcId`].[OutputValue]')

REGION=$(aws configure get region)

echo "
EKS_CLUSTER_NAME = ${EKS_CLUSTER_NAME}
LBCTL_REPO_URL   = ${LBCTL_REPO_URL}
VPCID            = ${VPCID}
REGION           = ${REGION}
"
```
### (ii)マニフェストの編集
取得したマニフェストの以下の部分を修正します
- 必須項目
    - クラスター名変更: `--cluster-name=your-cluster-name`の`your-cluster-name`を変更します
- EC2インスタンスのIMDSへのアクセスが制限されているまたはFargate利用時
    - 引数にVPC ID追加: `--aws-vpc-id=vpc-xxx`
    - リージョン追加: `--aws-region=region-code`
- Privateクラスター固有の追加(NATGW等によるインターネット接続不可時)
    - shield/waf無効化の追加: `--enable-shield=false`,`--enable-waf=false`,`--enable-wafv2=false`
    - Dockeイメージパス変更: `image:`をECRにPUSHしたイメージに変更

以下に変更例を示します。
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app.kubernetes.io/component: controller
    app.kubernetes.io/name: aws-load-balancer-controller
  name: aws-load-balancer-controller
  namespace: kube-system
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/component: controller
      app.kubernetes.io/name: aws-load-balancer-controller
  template:
    metadata:
      labels:
        app.kubernetes.io/component: controller
        app.kubernetes.io/name: aws-load-balancer-controller
    spec:
      containers:
      - args:
        - --cluster-name=your-cluster-name #<<== クラスター名を変更
        - --ingress-class=alb
        - --aws-vpc-id=vpc-xxxxxxxx        #<== 取得したVPC IDを入れて追加
        - --aws-region=region-code         #<== 取得したリージョンコードを入れて追加
        - --enable-shield=false            #<== 追加
        - --enable-waf=false               #<== 追加
        - --enable-wafv2=false             #<== 追加
        image: amazon/aws-alb-ingress-controller:v2.4.0 #<<== ECRのイメージのパス "ECRURI:latest"に変更する
        livenessProbe:
          failureThreshold: 2
```

また以下の部分を削除します。(前のステップで追加された IAM ロールを持つアノテーションが、コントローラーがデプロイされる際に上書きされるのを防ぐため)
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  labels:
    app.kubernetes.io/component: controller
    app.kubernetes.io/name: aws-load-balancer-controller
  name: aws-load-balancer-controller
  namespace: kube-system
---
```


### (iii)マニフェストの適用
```shell
#マニフェストの適用
#kubectl apply -f ファイル名
#以下はv2_4_0_full.yamlファイルの場合
kubectl apply -f v2_4_0_full.yaml
```
状態を確認します。
```shell
kubectl get deployment -n kube-system aws-load-balancer-controller


NAME                           READY   UP-TO-DATE   AVAILABLE   AGE
aws-load-balancer-controller   1/1     1            1           3m11s
```

## (5) サブネットを検知できるようにする
ALBを配置するPublic SubnetをAWS Load Balancer Controllerが検知できるようにするため、Public Subnetに以下のタグを追加します。
- 追加するタグ
    - key: `kubernetes.io/role/elb`
    - value: `1`

### (5)-(a)情報の取得
```shell
PUBSUB1ID=$(aws --output text cloudformation describe-stacks \
        --stack-name EksPoc-VPC \
        --query 'Stacks[].Outputs[?OutputKey==`PublicSubnet1Id`].[OutputValue]')

PUBSUB2ID=$(aws --output text cloudformation describe-stacks \
        --stack-name EksPoc-VPC \
        --query 'Stacks[].Outputs[?OutputKey==`PublicSubnet2Id`].[OutputValue]')

echo "
PUBSUB1ID = ${PUBSUB1ID}
PUBSUB2ID = ${PUBSUB2ID}
"
```
### (5)-(b)タグの追加
```shell
aws ec2 create-tags --resources ${PUBSUB1ID} ${PUBSUB2ID} --tags 'Key=kubernetes.io/role/elb,Value=1'
```

## (6)テスト
以下のようにIngress(ALB)、NodePortのサービス、とhttpdのPodで構成するサンプルを稼働させます。
![ingress arch](Documents/arch-pod_ingress_arch.svg)



### (6)-(a) 既存サービスの削除
ハンズオン(その2)までの定義がある場合はまず削除します。
```shell
kubectl delete -f k8s_define/httpd-service.yaml
kubectl delete -f httpd-deployment.yaml
```

### (6)-(b) 定義ファイルの生成
#### (i)リポジトリ情報の取得
```shell
REPO_URL=$(aws --output text cloudformation \
    describe-stacks --stack-name EksPoc-Ecr \
    --query 'Stacks[].Outputs[?OutputKey==`EcrRepositoryUri`].[OutputValue]' )
echo "
REPO_URL = ${REPO_URL}
"
```

#### (i) 定義ファイルの準備
```shell
#Deployment定義ファイルの作成
#環境固有となるECRレポジトリURL情報をDeploymentに設定します。
sed -e "s;REPO_URL;${REPO_URL};" k8s_define/httpd-ingress.yaml.template > httpd-ingress.yaml
cat httpd-ingress.yaml
```

### (6)-(c) DeploymentとServiceの適用
#### (i) 適用
```shell
kubectl apply -f httpd-ingress.yaml
```

状態を確認します。
```shell
kubectl get cm,deployment,pod,svc -o wide


NAME                         DATA   AGE
configmap/kube-root-ca.crt   1      2d3h

NAME                               READY   UP-TO-DATE   AVAILABLE   AGE   CONTAINERS   IMAGES                                                                 SELECTOR
deployment.apps/httpd-deployment   2/2     2            2           10m   httpd        616605178605.dkr.ecr.ap-northeast-1.amazonaws.com/ekspoc-repo:latest   app.kubernetes.io/name=httpd-pod

NAME                                   READY   STATUS    RESTARTS   AGE   IP             NODE                                              NOMINATED NODE   READINESS GATES
pod/httpd-deployment-ff96f4749-7fgcl   1/1     Running   0          10m   10.1.154.230   ip-10-1-147-224.ap-northeast-1.compute.internal   <none>           <none>
pod/httpd-deployment-ff96f4749-m5b6r   1/1     Running   0          10m   10.1.46.57     ip-10-1-60-36.ap-northeast-1.compute.internal     <none>           <none>

NAME                    TYPE        CLUSTER-IP       EXTERNAL-IP   PORT(S)        AGE    SELECTOR
service/httpd-service   NodePort    172.20.192.129   <none>        80:32679/TCP   10m    app.kubernetes.io/name=httpd-pod
service/kubernetes      ClusterIP   172.20.0.1       <none>        443/TCP        2d3h   <none>
```
#### (ii) 確認
マネージメントコンソールなどで、ALBのURLを確認し、ブラウザやcurlコマンドで`http://ALBのDNS`でアクセス可能か確認します。

接続できない場合は以下で原因を特定します。
- AWS Load Balancer Controllerを調査する
```shell
kubectl logs -n kube-system deployment.apps/aws-load-balancer-controller
```

- k8sのDeployment/service/ingressの調査方法
こちらを参考にします
https://aws.amazon.com/jp/premiumsupport/knowledge-center/eks-resolve-failed-health-check-alb-nlb/