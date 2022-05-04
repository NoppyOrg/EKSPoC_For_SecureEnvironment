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
### (3)-(c) VPCエンドポイント
```shell
aws --profile ${PROFILE} --region ${REGION} \
    cloudformation create-stack \
        --stack-name EksPoc-Vpce \
        --template-body "file://./src/vpce.yaml" 
```

## (3)IAMロール作成
```shell
aws --profile ${PROFILE} --region ${REGION} \
    cloudformation create-stack \
        --stack-name EksPoc-IAM \
        --template-body "file://./src/iam.yaml" \
        --capabilities CAPABILITY_IAM ;
```

## (4)インスタンス準備

```shell
#Bastion & DockerSG & kubectl
aws --profile ${PROFILE} --region ${REGION} \
    cloudformation create-stack \
        --stack-name EksPoc-Instances \
        --template-body "file://./src/instances.yaml" 
```