# aws-serverless-backend

Creates an api gateway with each route connected to a separate lambda.

## Features

- Creates an api gateway with all the requisite resources based on the paths provided
- Every method is mapped to its own Lambda
- An IAM user named like `api_name-lambda` is created that is given deployment access to the lambdas
- Currently only supports resources one path deep

## Usage

```hcl
provider "aws" {
    region = "us-east-1"
}

module "aws_serverless_backend" {
    source    = "dvargas92495/serverless-backend/aws"

    api_name = "example"
    paths = [
        "resource/get",
        "another_resource/post"
    ]
    domain = "example.com"
}
```

## Inputs

- `paths` are the list of path methods that your api supports.
- `api_name` is name given to the api.
- `tags` tags to add on to lambdas and api gateway
- `domain` the domain to map the api to.

## Output

- `rest_api_id` the id of the created rest api
- `access_key` the AWS_ACCESS_KEY_ID of the created user
- `secret_key` the AWS_SECRET_ACCESS_KEY of the created user