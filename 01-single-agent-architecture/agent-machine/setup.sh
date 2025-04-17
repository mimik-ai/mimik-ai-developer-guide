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
required_vars=("HOST_IP_ADDRESS" "HOST_PORT" "DEVELOPER_ID_TOKEN" "CLIENT_ID" "API_KEY" "MODEL_URL")
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        echo "Error: $var is not set in .env file"
        exit 1
    fi
done

# Set variables
HOST="http://$HOST_IP_ADDRESS:$HOST_PORT"
TOKEN_SCOPE="openid edge:mcm edge:clusters edge:account:associate"
TAR_NAME="milm-v1-1.9.1.tar"

echo "=== Starting AI Agent Deployment ==="

# Step 1: Get Target Device Information
echo "Step 1: Getting target device information..."
NODE_ID_RESPONSE=$(curl -s -X POST "$HOST/jsonrpc/v1" \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc": "2.0", "method": "getMe", "params": [], "id": 1}')
echo "Device information retrieved"

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

# Step 5: Deploy microservice using curl's multipart form upload
echo "Step 5: Deploying microservice..."
DEPLOY_RESPONSE=$(curl -s -X POST "$HOST/mcm/v1/images" \
    -H "Authorization: Bearer $EDGE_TOKEN" \
    -F "image=@../../deploy/$TAR_NAME" \
    -F "name=milm-v1")
echo "Microservice deployed"
echo "$DEPLOY_RESPONSE" | jq

# Step 6: Get Images
echo "Step 6: Getting images..."
IMAGES_RESPONSE=$(curl -s -X GET "$HOST/mcm/v1/images" \
    -H "Authorization: Bearer $EDGE_TOKEN")
echo "Images retrieved:"
echo "$IMAGES_RESPONSE" | jq

# Step 7: Start microservice
echo "Step 7: Starting microservice..."
START_RESPONSE=$(curl -s -X POST "$HOST/mcm/v1/containers" \
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
echo "Microservice started"

# Step 8: Get Containers
echo "Step 8: Getting containers..."
CONTAINERS_RESPONSE=$(curl -s -X GET "$HOST/mcm/v1/containers" \
    -H "Authorization: Bearer $EDGE_TOKEN")
echo "Containers retrieved:"
echo "$CONTAINERS_RESPONSE" | jq

# Step 9: Download model using streaming API (SSE)
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

# Step 10: View deployed models
echo "Step 10: Viewing deployed models..."
MODELS_RESPONSE=$(curl -s -X GET "$HOST/api/milm/v1/models" \
    -H "Content-Type: application/json" \
    -H "Authorization: bearer $API_KEY")
echo "Deployed models:"
echo "$MODELS_RESPONSE" | jq

# Step 11: Test the model with a prompt using streaming API
echo "Step 11: Testing the model with a prompt..."
echo "Making a request to the model. This may take a minute..."
echo "Streaming response:"
curl -N -X POST "$HOST/api/milm/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Accept: text/event-stream" \
    -d '{
        "model": "Llama-3.2-1B-Instruct-GGUF",
        "messages": [
            { "role": "user", "content": "Who were the first 3 Presidents of the United States" }
        ],
        "stream": true
    }'

echo -e "\n\n=== AI Agent Deployment Complete ==="