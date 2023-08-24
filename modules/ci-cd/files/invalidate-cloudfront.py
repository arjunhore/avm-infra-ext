import boto3
import time

client = boto3.client("cloudfront")

code_pipeline = boto3.client("codepipeline")


def lambda_handler(event, context):
    job_id = event["CodePipeline.job"]["id"]
    distribution_id = event["CodePipeline.job"]["data"]["actionConfiguration"][
        "configuration"
    ]["UserParameters"]

    invalidation = client.create_invalidation(
        DistributionId=distribution_id,
        InvalidationBatch={
            "Paths": {"Quantity": 1, "Items": ["/*"]},
            "CallerReference": str(time.time()),
        },
    )
    code_pipeline.put_job_success_result(jobId=job_id)
