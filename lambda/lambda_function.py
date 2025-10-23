import json
import os
import uuid
import time
import boto3
from boto3.dynamodb.conditions import Key
from decimal import Decimal

TABLE_NAME = os.environ.get("TABLE_NAME", "NotesTable")
dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(TABLE_NAME)

# Helper function to convert Decimal to int/float for JSON serialization
def decimal_to_number(obj):
    if isinstance(obj, list):
        return [decimal_to_number(i) for i in obj]
    elif isinstance(obj, dict):
        return {k: decimal_to_number(v) for k, v in obj.items()}
    elif isinstance(obj, Decimal):
        return int(obj) if obj % 1 == 0 else float(obj)
    else:
        return obj

def response(status, body):
    return {
        "statusCode": status,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Headers": "Content-Type,Authorization",
            "Access-Control-Allow-Methods": "OPTIONS,GET,POST,PUT,DELETE"
        },
        "body": json.dumps(body)
    }

def get_user_id(event):
    """Extract user ID from JWT claims in HTTP API v2 format"""
    try:
        # HTTP API v2 with JWT authorizer structure
        request_context = event.get("requestContext", {})
        authorizer = request_context.get("authorizer", {})
        
        # Try JWT claims first (HTTP API v2)
        jwt = authorizer.get("jwt", {})
        if jwt:
            claims = jwt.get("claims", {})
            user_id = claims.get("sub") or claims.get("cognito:username") or claims.get("username")
            if user_id:
                print(f"Found user_id from JWT: {user_id}")
                return user_id
        
        # Fallback for other formats
        claims = authorizer.get("claims", {})
        if claims:
            user_id = claims.get("sub") or claims.get("cognito:username") or claims.get("username")
            if user_id:
                print(f"Found user_id from claims: {user_id}")
                return user_id
                
        print("No user_id found in event")
        print(f"Event structure: {json.dumps(event, default=str)}")
        return None
        
    except Exception as e:
        print(f"Error extracting user_id: {str(e)}")
        print(f"Event: {json.dumps(event, default=str)}")
        return None

def lambda_handler(event, context):
    print(f"Received event: {json.dumps(event, default=str)}")
    
    # Get HTTP method - try multiple locations
    request_context = event.get("requestContext", {})
    http_context = request_context.get("http", {})
    method = http_context.get("method") or event.get("httpMethod", "")
    
    print(f"HTTP Method: {method}")
    
    # Handle CORS preflight - OPTIONS requests don't need authorization
    if method == "OPTIONS":
        return response(200, {"message": "CORS preflight OK"})

    # Get user ID from JWT claims
    user_id = get_user_id(event)
    if not user_id:
        return response(401, {"message": "Unauthorized - no user claims found"})

    # Get path parameters
    path_params = event.get("pathParameters") or {}
    
    # Parse body
    body = {}
    try:
        if event.get("body"):
            body = json.loads(event.get("body"))
            print(f"Parsed body: {body}")
    except Exception as e:
        print(f"Error parsing body: {str(e)}")
        body = {}

    # POST - Create note
    if method == "POST":
        note_id = str(uuid.uuid4())
        item = {
            "userId": user_id,
            "noteId": note_id,
            "title": body.get("title", ""),
            "content": body.get("content", ""),
            "createdAt": int(time.time())
        }
        print(f"Creating note: {item}")
        table.put_item(Item=item)
        return response(201, {"message": "Note created", "noteId": note_id})

    # GET - Fetch notes
    if method == "GET":
        note_id = path_params.get("noteId")
        if note_id:
            # Get single note
            try:
                print(f"Fetching note: {note_id} for user: {user_id}")
                res = table.get_item(Key={"userId": user_id, "noteId": note_id})
                item = res.get("Item")
                if not item:
                    return response(404, {"message": "Note not found"})
                return response(200, item)
            except Exception as e:
                print(f"Error fetching single note: {str(e)}")
                return response(500, {"message": "Error fetching note", "error": str(e)})
        else:
            # Get all notes for user
            try:
                print(f"Fetching all notes for user: {user_id}")
                print(f"Table name: {TABLE_NAME}")
                res = table.query(KeyConditionExpression=Key("userId").eq(user_id))
                items = res.get("Items", [])
                print(f"Found {len(items)} notes")
                # Convert Decimal to float for JSON serialization
                items_clean = []
                for item in items:
                    clean_item = {}
                    for key, value in item.items():
                        if isinstance(value, type(boto3.dynamodb.types.Decimal(0))):
                            clean_item[key] = int(value)
                        else:
                            clean_item[key] = value
                    items_clean.append(clean_item)
                return response(200, {"items": items_clean})
            except Exception as e:
                print(f"Error fetching notes: {str(e)}")
                print(f"User ID: {user_id}")
                import traceback
                print(f"Traceback: {traceback.format_exc()}")
                return response(500, {"message": "Error fetching notes", "error": str(e)})

    # PUT - Update note
    if method == "PUT":
        note_id = path_params.get("noteId")
        if not note_id:
            return response(400, {"message": "noteId required in path"})
        
        update_parts = []
        attr_values = {}
        
        if "title" in body:
            update_parts.append("title = :title")
            attr_values[":title"] = body["title"]
        if "content" in body:
            update_parts.append("content = :content")
            attr_values[":content"] = body["content"]
            
        if not update_parts:
            return response(400, {"message": "No fields to update"})
            
        update_expr = "SET " + ", ".join(update_parts)
        print(f"Updating note {note_id}: {update_expr}")
        
        table.update_item(
            Key={"userId": user_id, "noteId": note_id},
            UpdateExpression=update_expr,
            ExpressionAttributeValues=attr_values
        )
        return response(200, {"message": "Note updated"})

    # DELETE - Delete note
    if method == "DELETE":
        note_id = path_params.get("noteId")
        if not note_id:
            return response(400, {"message": "noteId required in path"})
        
        print(f"Deleting note: {note_id} for user: {user_id}")
        table.delete_item(Key={"userId": user_id, "noteId": note_id})
        return response(200, {"message": "Note deleted"})

    return response(405, {"message": "Method not allowed"})