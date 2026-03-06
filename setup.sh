se#!/usr/bin/env bash
set -euo pipefail

# ╔══════════════════════════════════════════════════════╗
# ║  Setup AWS infra for silniki-trojfazowe.pl            ║
# ║  S3 + CloudFront + Route53 + CodeBuild                ║
# ╚══════════════════════════════════════════════════════╝

REGION="eu-north-1"
DOMAIN="silniki-trojfazowe.pl"
BUCKET="www.${DOMAIN}"
HOSTED_ZONE_ID="Z0838271M7KIYKHWWYLP"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "Account:  $ACCOUNT_ID"
echo "Domain:   $DOMAIN"
echo "Bucket:   $BUCKET"
echo ""

# ────────────────────────────────────────
# 1. S3 Bucket (static website)
# ────────────────────────────────────────
echo "1/5 Creating S3 bucket..."
aws s3 mb "s3://${BUCKET}" --region "$REGION" 2>/dev/null || echo "  Bucket exists"

# Wyłącz block public access
aws s3api put-public-access-block \
  --bucket "$BUCKET" \
  --public-access-block-configuration "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false" \
  --region "$REGION"

# Website config
aws s3 website "s3://${BUCKET}" --index-document index.html --error-document 404.html --region "$REGION"

# Bucket policy
aws s3api put-bucket-policy --bucket "$BUCKET" --policy '{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "PublicRead",
    "Effect": "Allow",
    "Principal": "*",
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::'"$BUCKET"'/*"
  }]
}' --region "$REGION"

echo "  S3 bucket ready"

# ────────────────────────────────────────
# 2. ACM Certificate (us-east-1 for CloudFront!)
# ────────────────────────────────────────
echo "2/5 Requesting ACM certificate (us-east-1)..."

CERT_ARN=$(aws acm request-certificate \
  --domain-name "$DOMAIN" \
  --subject-alternative-names "www.${DOMAIN}" \
  --validation-method DNS \
  --region us-east-1 \
  --query 'CertificateArn' --output text)

echo "  Certificate ARN: $CERT_ARN"
echo ""
echo "  ⚠️  WAŻNE: Dodaj rekordy DNS do walidacji certyfikatu!"
echo "  Sprawdź w konsoli ACM (us-east-1) lub uruchom:"
echo "  aws acm describe-certificate --certificate-arn $CERT_ARN --region us-east-1 --query 'Certificate.DomainValidationOptions'"
echo ""
echo "  Poczekaj na walidację (może zająć kilka minut)."
echo "  Naciśnij Enter gdy certyfikat będzie ISSUED..."
read -r

# ────────────────────────────────────────
# 3. CloudFront Distribution
# ────────────────────────────────────────
echo "3/5 Creating CloudFront distribution..."

CF_CONFIG=$(cat <<EOF
{
  "CallerReference": "silniki-trojfazowe-$(date +%s)",
  "Aliases": {
    "Quantity": 2,
    "Items": ["${DOMAIN}", "www.${DOMAIN}"]
  },
  "DefaultRootObject": "index.html",
  "Origins": {
    "Quantity": 1,
    "Items": [{
      "Id": "S3-${BUCKET}",
      "DomainName": "${BUCKET}.s3-website.${REGION}.amazonaws.com",
      "CustomOriginConfig": {
        "HTTPPort": 80,
        "HTTPSPort": 443,
        "OriginProtocolPolicy": "http-only"
      }
    }]
  },
  "DefaultCacheBehavior": {
    "TargetOriginId": "S3-${BUCKET}",
    "ViewerProtocolPolicy": "redirect-to-https",
    "AllowedMethods": {
      "Quantity": 2,
      "Items": ["GET", "HEAD"]
    },
    "ForwardedValues": {
      "QueryString": false,
      "Cookies": { "Forward": "none" }
    },
    "MinTTL": 0,
    "DefaultTTL": 86400,
    "MaxTTL": 31536000,
    "Compress": true
  },
  "CustomErrorResponses": {
    "Quantity": 1,
    "Items": [{
      "ErrorCode": 404,
      "ResponsePagePath": "/404.html",
      "ResponseCode": "404",
      "ErrorCachingMinTTL": 60
    }]
  },
  "ViewerCertificate": {
    "ACMCertificateArn": "${CERT_ARN}",
    "SSLSupportMethod": "sni-only",
    "MinimumProtocolVersion": "TLSv1.2_2021"
  },
  "Enabled": true,
  "HttpVersion": "http2and3",
  "Comment": "silniki-trojfazowe.pl"
}
EOF
)

CF_DIST=$(aws cloudfront create-distribution \
  --distribution-config "$CF_CONFIG" \
  --query 'Distribution.{id:Id,domain:DomainName}' \
  --output json)

CF_ID=$(echo "$CF_DIST" | grep -o '"id":"[^"]*"' | cut -d'"' -f4)
CF_DOMAIN=$(echo "$CF_DIST" | grep -o '"domain":"[^"]*"' | cut -d'"' -f4)

echo "  CloudFront ID:     $CF_ID"
echo "  CloudFront Domain: $CF_DOMAIN"

# ────────────────────────────────────────
# 4. Route53 DNS records
# ────────────────────────────────────────
echo "4/5 Creating Route53 records..."

aws route53 change-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch '{
    "Changes": [
      {
        "Action": "UPSERT",
        "ResourceRecordSet": {
          "Name": "'"$DOMAIN"'",
          "Type": "A",
          "AliasTarget": {
            "HostedZoneId": "Z2FDTNDATAQYW2",
            "DNSName": "'"$CF_DOMAIN"'",
            "EvaluateTargetHealth": false
          }
        }
      },
      {
        "Action": "UPSERT",
        "ResourceRecordSet": {
          "Name": "www.'"$DOMAIN"'",
          "Type": "A",
          "AliasTarget": {
            "HostedZoneId": "Z2FDTNDATAQYW2",
            "DNSName": "'"$CF_DOMAIN"'",
            "EvaluateTargetHealth": false
          }
        }
      }
    ]
  }'

echo "  DNS records created"

# ────────────────────────────────────────
# 5. CodeBuild project
# ────────────────────────────────────────
echo "5/5 Creating CodeBuild project..."

aws s3 mb "s3://silniki-trojfazowe-pl-source" --region "$REGION" 2>/dev/null || echo "  Source bucket exists"

aws codebuild create-project \
  --name silniki-trojfazowe-pl \
  --source '{"type":"S3","location":"silniki-trojfazowe-pl-source/source.zip"}' \
  --artifacts '{"type":"NO_ARTIFACTS"}' \
  --environment '{"type":"LINUX_CONTAINER","image":"aws/codebuild/amazonlinux2-x86_64-standard:5.0","computeType":"BUILD_GENERAL1_SMALL"}' \
  --service-role "arn:aws:iam::'"$ACCOUNT_ID"':role/silnik-elektryczny-pl-codebuild-role" \
  --region "$REGION" \
  --timeout-in-minutes 10 \
  --logs-config '{"cloudWatchLogs":{"status":"ENABLED","groupName":"/aws/codebuild/silniki-trojfazowe-pl"}}' \
  2>/dev/null || echo "  Project exists"

# Dodaj uprawnienia S3 dla nowego bucketa
aws iam put-role-policy \
  --role-name silnik-elektryczny-pl-codebuild-role \
  --policy-name codebuild-trojfazowe-s3 \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": ["s3:PutObject","s3:GetObject","s3:DeleteObject","s3:ListBucket","s3:GetBucketLocation"],
      "Resource": ["arn:aws:s3:::www.silniki-trojfazowe.pl","arn:aws:s3:::www.silniki-trojfazowe.pl/*","arn:aws:s3:::silniki-trojfazowe-pl-source","arn:aws:s3:::silniki-trojfazowe-pl-source/*"]
    }]
  }'

# Dodaj uprawnienie CodeBuild do roli EB (żeby backend mógł triggerować rebuild)
aws iam put-role-policy \
  --role-name aws-elasticbeanstalk-ec2-role \
  --policy-name satellite-rebuild-trojfazowe \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": ["codebuild:StartBuild","codebuild:BatchGetBuilds","codebuild:ListBuildsForProject"],
      "Resource": "arn:aws:codebuild:'"$REGION"':'"$ACCOUNT_ID"':project/silniki-trojfazowe-pl"
    }]
  }'

# EventBridge cron co 30 min
LAMBDA_ARN="arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:silnik-elektryczny-rebuild"

aws events put-rule \
  --name silniki-trojfazowe-pl-rebuild-cron \
  --schedule-expression "rate(30 minutes)" \
  --state ENABLED \
  --description "Rebuild silniki-trojfazowe.pl co 30 min" \
  --region "$REGION" 2>/dev/null || true

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  DONE!                                               ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  CloudFront ID:  $CF_ID"
echo "║  CloudFront:     $CF_DOMAIN"
echo "║  Certificate:    $CERT_ARN"
echo "║  S3 Bucket:      $BUCKET"
echo "║  CodeBuild:      silniki-trojfazowe-pl"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "ZAPISZ CloudFront Distribution ID: $CF_ID"
echo "Będzie potrzebny w buildspec.yml"