#!/bin/bash

# Check if .env file exists
if [ ! -f .env ]; then
    echo "Error: .env file not found. Please create a .env file with the required variables."
    exit 1
fi

# Load environment variables from .env file
set -a
source .env
set +a

# Check if required environment variables are set
required_vars=(
  "HOST_IP_ADDRESS" 
  "DEVELOPER_ID_TOKEN" 
  "CLIENT_ID" 
  "API_KEY"
  "AGENT_COLLECTION_NAME"
  "MODEL_URL"
  "NODE_ID_AGENT_1"
  "NODE_ID_COORDINATOR"
)

for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        echo "Error: $var is not set in .env file"
        exit 1
    fi
done

# Set variables
HOST="http://$HOST_IP_ADDRESS:8083"
TOKEN_SCOPE="openid edge:mcm edge:clusters edge:account:associate"
MAI_TAR_NAME="mai-v1-1.8.1.tar"
MLM_TAR_NAME="milm-v1-1.9.1.tar"
SUMMARY_TEMPLATE="Must start reply with 'Here is a summary:'.  Given the context below, synthesize the information and provide a unified, concise summary in short point form.\n\n<context>{{mergedContent}}</context>"

echo "=== Starting Agent Collection Deployment ==="

# Step 1: Get Target Device Information
echo "Step 1: Getting target device information..."
NODE_INFO_RESPONSE=$(curl -s -X POST "$HOST/jsonrpc/v1" \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc": "2.0", "method": "getMe", "params": [], "id": 1}')
echo "Device information retrieved"
echo "$NODE_INFO_RESPONSE" | jq

# Step 2: Get edgeIdToken
echo "Step 2: Getting edge ID token..."
EDGE_TOKEN_RESPONSE=$(curl -s -X POST "$HOST/jsonrpc/v1" \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc": "2.0", "method": "getEdgeIdToken", "params": [], "id": 1}')
EDGE_ID_TOKEN=$(echo $EDGE_TOKEN_RESPONSE | jq -r '.result.id_token')

if [ -z "$EDGE_ID_TOKEN" ] || [ "$EDGE_ID_TOKEN" == "null" ]; then
    echo "Error: Failed to get edge ID token"
    echo "Response: $EDGE_TOKEN_RESPONSE"
    exit 1
fi
echo "Edge ID token retrieved"

# Step 3: Get Access Token
echo "Step 3: Getting access token..."
ACCESS_TOKEN_RESPONSE=$(curl -s -L -X POST "https://devconsole-mid.mimik.com/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "client_id=$CLIENT_ID&grant_type=id_token_signin&id_token=$DEVELOPER_ID_TOKEN&scope=$TOKEN_SCOPE&edge_id_token=$EDGE_ID_TOKEN")
EDGE_TOKEN=$(echo $ACCESS_TOKEN_RESPONSE | jq -r '.access_token')

if [ -z "$EDGE_TOKEN" ] || [ "$EDGE_TOKEN" == "null" ]; then
    echo "Error: Failed to get access token"
    echo "Response: $ACCESS_TOKEN_RESPONSE"
    exit 1
fi
echo "Access token retrieved"

# Step 4: Associate device with account
echo "Step 4: Associating device with account..."
ASSOCIATE_RESPONSE=$(curl -s -X POST "$HOST/jsonrpc/v1" \
    -H "Content-Type: application/json" \
    -d "{\"jsonrpc\": \"2.0\", \"method\": \"associateAccount\", \"params\": [\"$EDGE_TOKEN\"], \"id\": 1}")
echo "Device associated with account"
echo "$ASSOCIATE_RESPONSE" | jq

# Step 5: Deploy mAI microservice
echo "Step 5: Deploying mAI microservice..."
MAI_DEPLOY_RESPONSE=$(curl -s -X POST "$HOST/mcm/v1/images" \
    -H "Authorization: Bearer $EDGE_TOKEN" \
    -F "image=@../../deploy/$MAI_TAR_NAME")
echo "mAI microservice deployed"
echo "$MAI_DEPLOY_RESPONSE" | jq

# Step 6: Start mAI Microservice
echo "Step 6: Starting mAI microservice..."
MAI_START_RESPONSE=$(curl -s -X POST "$HOST/mcm/v1/containers" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $EDGE_TOKEN" \
    -d "{
        \"name\": \"mai-v1\",
        \"image\": \"mai-v1\",
        \"env\": {
          \"MCM.BASE_API_PATH\": \"/mai/v1\",
          \"MCM.API_ALIAS\": \"true\",
          \"EDGE_ACCESS_TOKEN\": \"$EDGE_TOKEN\",
          \"API_KEY\": \"$API_KEY\",
          \"MCM.OTEL_SUPPORT\": \"true\"
        }
    }")
echo "mAI microservice started"
echo "$MAI_START_RESPONSE" | jq

# Step 7: Deploy mILM microservice
echo "Step 7: Deploying mILM microservice..."
MLM_DEPLOY_RESPONSE=$(curl -s -X POST "$HOST/mcm/v1/images" \
    -H "Authorization: Bearer $EDGE_TOKEN" \
    -F "image=@../../deploy/$MLM_TAR_NAME")
echo "mILM microservice deployed"
echo "$MLM_DEPLOY_RESPONSE" | jq

# Step 8: Start mILM microservice
echo "Step 8: Starting mILM microservice..."
MLM_START_RESPONSE=$(curl -s -X POST "$HOST/mcm/v1/containers" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $EDGE_TOKEN" \
    -d "{
        \"name\": \"milm-v1\",
        \"image\": \"milm-v1\",
        \"env\": {
          \"MCM.BASE_API_PATH\": \"/milm/v1\",
          \"API_KEY\": \"$API_KEY\",
          \"MCM.API_ALIAS\": \"true\",
          \"MCM.OTEL_SUPPORT\": \"true\"
        }
    }")
echo "mILM microservice started"
echo "$MLM_START_RESPONSE" | jq

# Step 9: Download model using streaming API
echo "Step 9: Downloading model (this may take a while)..."
echo "Starting model download. Streaming progress:"
curl -N -X POST "$HOST/api/milm/v1/models" \
    -H "Content-Type: application/json" \
    -H "Authorization: bearer $API_KEY" \
    -H "Accept: text/event-stream" \
    -d "{
        \"id\": \"Llama-3.2-1B-Instruct-GGUF\",
        \"object\": \"model\",
        \"kind\": \"llm\",
        \"url\": \"$MODEL_URL\"
    }"
echo -e "\nModel download complete"

# Step 10: Get Images to verify deployment
echo "Step 10: Verifying image deployment..."
IMAGES_RESPONSE=$(curl -s -X GET "$HOST/mcm/v1/images" \
    -H "Authorization: Bearer $EDGE_TOKEN")
echo "Deployed images:"
echo "$IMAGES_RESPONSE" | jq

# Step 11: Get Containers to verify they're running
echo "Step 11: Verifying container status..."
CONTAINERS_RESPONSE=$(curl -s -X GET "$HOST/mcm/v1/containers" \
    -H "Authorization: Bearer $EDGE_TOKEN")
echo "Running containers:"
echo "$CONTAINERS_RESPONSE" | jq

# Step 12: View deployed models
echo "Step 12: Viewing deployed models..."
MODELS_RESPONSE=$(curl -s -X GET "$HOST/api/milm/v1/models" \
    -H "Content-Type: application/json" \
    -H "Authorization: bearer $API_KEY")
echo "Deployed models:"
echo "$MODELS_RESPONSE" | jq

# Step 13: Declare the Agent Collection and the synthesis prompt
echo "Step 13: Declaring Agent Collection..."
AGENT_RESPONSE=$(curl -s -X POST "$HOST/api/mai/v1/models" \
    -H "Content-Type: application/json" \
    -H "Authorization: bearer $API_KEY" \
    -d "{
        \"id\": \"$AGENT_COLLECTION_NAME\",
        \"object\": \"model\",
        \"modelfile\": {
            \"prompts\": [
                {
                    \"url\": \"$NODE_ID_AGENT_1@mmesh/$CLIENT_ID/milm/v1/chat/completions\",
                    \"model\": \"Llama-3.2-1B-Instruct-GGUF\",
                    \"apikey\": \"Bearer $API_KEY\",
                    \"required\": true
                }
            ],
            \"summary\": {
                \"template\": \"$SUMMARY_TEMPLATE\",
                \"url\": \"$NODE_ID_COORDINATOR@mmesh/$CLIENT_ID/milm/v1/chat/completions\",
                \"model\": \"Llama-3.2-1B-Instruct-GGUF\",
                \"apikey\": \"Bearer $API_KEY\",
                \"required\": true
            }
        },
        \"owned_by\": \"mimik\"
    }")
echo "Agent Collection declared"
echo "$AGENT_RESPONSE" | jq

# Step 14: View the collections on the machine
echo "Step 14: Viewing agent collections..."
COLLECTIONS_RESPONSE=$(curl -s -X GET "$HOST/api/mai/v1/models" \
    -H "Content-Type: application/json" \
    -H "Authorization: bearer $API_KEY")
echo "Agent collections:"
echo "$COLLECTIONS_RESPONSE" | jq

# Step 15: Exercise the Coordinator Machine by submitting an initial prompt
echo "Step 15: Testing with initial prompt..."
echo "Submitting initial prompt. Streaming response:"
curl -N -X POST "$HOST/api/mai/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: bearer $API_KEY" \
    -H "Accept: text/event-stream" \
    -d "{ 
        \"model\": \"$AGENT_COLLECTION_NAME\",
        \"messages\": [ 
            { \"role\": \"user\", \"content\": \"Give me the 3 most popular sports in the United States.\" }
        ], 
        \"stream\": true
    }"
echo -e "\nInitial prompt response complete"

# Step 16: Exercise the Coordinator Machine by submitting a followup prompt
echo "Step 16: Testing with followup prompt..."
echo "Submitting followup prompt. Streaming response:"
curl -N -X POST "$HOST/api/mai/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: bearer $API_KEY" \
    -H "Accept: text/event-stream" \
    -d "{ 
        \"model\": \"$AGENT_COLLECTION_NAME\",
        \"messages\": [ 
            { \"role\": \"user\", \"content\": \"What are the teams in the most popular sports.\" }
        ], 
        \"stream\": true
    }"
echo -e "\nFollowup prompt response complete"

# Step 17: View the logs
echo "Step 17: Viewing logs..."
LOGS_RESPONSE=$(curl -s -X GET "$HOST/api/mai/v1/logs" \
    -H "Authorization: bearer $API_KEY")
echo "Logs:"
echo "$LOGS_RESPONSE" | jq

echo -e "\n=== Agent Collection Deployment Complete ==="