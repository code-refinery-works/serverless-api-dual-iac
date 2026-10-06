import * as cdk from "aws-cdk-lib";
import { Construct } from "constructs";
import * as dynamodb from "aws-cdk-lib/aws-dynamodb";
import * as kms from "aws-cdk-lib/aws-kms";
import * as lambda from "aws-cdk-lib/aws-lambda";
import * as lambdaNode from "aws-cdk-lib/aws-lambda-nodejs";
import * as apigwv2 from "aws-cdk-lib/aws-apigatewayv2";
import * as apigwv2Int from "aws-cdk-lib/aws-apigatewayv2-integrations";
import * as logs from "aws-cdk-lib/aws-logs";
import * as cloudwatch from "aws-cdk-lib/aws-cloudwatch";
import * as iam from "aws-cdk-lib/aws-iam";

interface Props extends cdk.StackProps { projectName: string; }

export class ServerlessApiStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: Props) {
    super(scope, id, props);
    const { projectName } = props;

    // KMS
    const key = new kms.Key(this, "Key", {
      alias: `alias/${projectName}`,
      enableKeyRotation: true,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });

    // DynamoDB
    const table = new dynamodb.Table(this, "Table", {
      tableName: `${projectName}-items`,
      partitionKey: { name: "pk", type: dynamodb.AttributeType.STRING },
      sortKey:      { name: "sk", type: dynamodb.AttributeType.STRING },
      billingMode:  dynamodb.BillingMode.PAY_PER_REQUEST,
      encryption:   dynamodb.TableEncryption.CUSTOMER_MANAGED,
      encryptionKey: key,
      pointInTimeRecovery: true,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });

    // CloudWatch Log Groups
    const lambdaLogGroup = new logs.LogGroup(this, "LambdaLogs", {
      logGroupName: `/aws/lambda/${projectName}`,
      retention: logs.RetentionDays.ONE_MONTH,
      encryptionKey: key,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });
    const apigwLogGroup = new logs.LogGroup(this, "ApiGwLogs", {
      logGroupName: `/aws/apigateway/${projectName}`,
      retention: logs.RetentionDays.ONE_MONTH,
      encryptionKey: key,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    // Lambda
    const fn = new lambdaNode.NodejsFunction(this, "Handler", {
      functionName: projectName,
      entry: "src/handlers/index.ts",
      handler: "handler",
      runtime: lambda.Runtime.NODEJS_20_X,
      timeout: cdk.Duration.seconds(29),
      tracing: lambda.Tracing.ACTIVE,
      logGroup: lambdaLogGroup,
      environment: {
        TABLE_NAME: table.tableName,
        POWERTOOLS_SERVICE_NAME: projectName,
      },
      bundling: { minify: true, sourceMap: true },
    });

    // Least-privilege: grant only required DynamoDB actions
    fn.addToRolePolicy(new iam.PolicyStatement({
      sid: "DynamoDBMinimal",
      actions: ["dynamodb:GetItem","dynamodb:PutItem","dynamodb:UpdateItem","dynamodb:DeleteItem","dynamodb:Query","dynamodb:Scan"],
      resources: [table.tableArn],
    }));
    key.grantEncryptDecrypt(fn);

    // API Gateway HTTP API
    const api = new apigwv2.HttpApi(this, "HttpApi", {
      apiName: projectName,
      defaultIntegration: new apigwInt.HttpLambdaIntegration("LambdaInt", fn),
    });
    // Throttling on default stage via CfnStage override
    const cfnStage = api.defaultStage?.node.defaultChild as apigwv2.CfnStage;
    cfnStage.defaultRouteSettings = {
      throttlingBurstLimit: 500,
      throttlingRateLimit: 1000,
    };
    cfnStage.accessLogSettings = {
      destinationArn: apigwLogGroup.logGroupArn,
      format: JSON.stringify({ requestId:"$context.requestId", ip:"$context.identity.sourceIp", method:"$context.httpMethod", path:"$context.path", status:"$context.status", latency:"$context.responseLatency" }),
    };

    // CloudWatch Alarms
    const errors      = fn.metricErrors({ period: cdk.Duration.minutes(1), statistic: "Sum" });
    const invocations = fn.metricInvocations({ period: cdk.Duration.minutes(1), statistic: "Sum" });
    new cloudwatch.MathExpression({ expression: "errors/invocations*100", usingMetrics: { errors, invocations } })
      .createAlarm(this, "LambdaErrorRateAlarm", {
        alarmName: `${projectName}-lambda-error-rate`,
        threshold: 1,
        evaluationPeriods: 2,
        treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
      });

    new cloudwatch.Metric({
      namespace: "AWS/DynamoDB", metricName: "ThrottledRequests",
      dimensionsMap: { TableName: table.tableName },
      period: cdk.Duration.minutes(1), statistic: "Sum",
    }).createAlarm(this, "DynamoThrottleAlarm", {
      alarmName: `${projectName}-dynamo-throttle`,
      threshold: 0,
      evaluationPeriods: 1,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    });

    // Outputs
    new cdk.CfnOutput(this, "ApiEndpoint",    { value: api.apiEndpoint });
    new cdk.CfnOutput(this, "TableName",      { value: table.tableName });
    new cdk.CfnOutput(this, "KmsKeyArn",      { value: key.keyArn });
    new cdk.CfnOutput(this, "FunctionName",   { value: fn.functionName });
  }
}

// Fix: import alias for integration (avoid name collision)
import * as apigwInt from "aws-cdk-lib/aws-apigatewayv2-integrations";