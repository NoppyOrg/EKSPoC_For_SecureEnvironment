# CloudFormation: EKS PoC For Secure Environment
セキュアな環境でEKSを利用するための検証用環境を作成するCloudFormationテンプレートです。
# 作成環境
![CFn_configuration](./Documents/EKS_PoC.png)

# ハンズオン(その１): シンプルなEKSプライベートクラスター作成
シンプルなEKSプライベートクラスターを作成し、動作テストでpodを動かします。

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

NAME               READY   UP-TO-DATE   AVAILABLE   AGE     CONTAINERS   IMAGES                                                                 SELECTOR
httpd-deployment   3/3     3            3           9m13s   httpd        616605178605.dkr.ecr.ap-northeast-1.amazonaws.com/ekspoc-repo:latest   app=httpd-pod
```
- Podの状態確認
```shell
kubectl get pods -o wide 

NAME                               READY   STATUS    RESTARTS   AGE     IP            NODE                                             NOMINATED NODE   READINESS GATES
httpd-deployment-dbb8b7f8c-nbkg2   1/1     Running   0          9m55s   10.1.43.41    ip-10-1-56-7.ap-northeast-1.compute.internal     <none>           <none>
httpd-deployment-dbb8b7f8c-vzpjj   1/1     Running   0          9m55s   10.1.34.253   ip-10-1-33-162.ap-northeast-1.compute.internal   <none>           <none>
httpd-deployment-dbb8b7f8c-xk7gw   1/1     Running   0          9m55s   10.1.47.88    ip-10-1-33-162.ap-northeast-1.compute.internal   <none>           <none>
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







## (7) OIDCプロバイダ
### (7)-(a) jqのインストール
コマンドの中でJSONデータを処理するjqコマンドを利用するため、予めjqをインストールします。
```shell
sudo yum -y install jq
```
### (7)-(b) OIDCプロバイダのサムプリント取得
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
### (7)-(c) OIDCプロバイダ作成
```shell
aws iam create-open-id-connect-provider \
    --url "${OpenIdConnectIssuerUrl}" \
    --thumbprint-list "${THUMBPRINT}" \
    --client-id-list "sts.amazonaws.com"

```

## (8) AutoScaling設定




https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/cloudprovider/aws/README.md

https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/cloudprovider/aws/CA_with_AWS_IAM_OIDC.md

## (9) ELB設定