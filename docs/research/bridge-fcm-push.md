# Push Notifications from Dart Bridge Process - Research Findings

**Ticket #9** | **Status: Resolved**

## Executive Summary

A Dart bridge process running on a Linux server can implement Firebase Cloud Messaging (FCM) push notifications through **two primary approaches**:

1. **Firebase Admin SDK for Dart (Recommended)** - High-level SDK with automatic token management
2. **FCM HTTP v1 API Direct Calls** - Lower-level approach using raw HTTP requests

Both approaches use **Firebase service account credentials** for authentication. No special bridging infrastructure (like Cloudflare Access) is required since the bridge is a trusted server environment.

---

## Table of Contents

- [Recommendation](#recommendation)
- [Approach 1: Firebase Admin SDK for Dart](#approach-1-firebase-admin-sdk-for-dart)
- [Approach 2: FCM HTTP v1 API (Raw Protocol)](#approach-2-fcm-http-v1-api-raw-protocol)
- [Authentication & Authorization](#authentication--authorization)
- [Credentials Storage Best Practices](#credentials-storage-best-practices)
- [Token Lifetime & Refresh](#token-lifetime--refresh)
- [Platform-Specific Configuration](#platform-specific-configuration)
- [Sample Implementation](#sample-implementation)
- [Security Considerations](#security-considerations)

---

## Recommendation

**Primary Recommendation**: Use the **Firebase Admin SDK for Dart** (`package:firebase_admin_sdk`)

### Rationale

1. **Production-Ready**: Official Firebase SDK (0.5.6, published by firebase.google.com)
2. **Automatic Token Management**: Handles OAuth2 token refresh automatically
3. **Type-Safe**: Strongly typed Dart/Flutter implementation
4. **Feature Complete**: Supports send, sendEach, sendEachForMulticast, topic management
5. **Lower Risk**: Less error-prone than manual HTTP implementation

### Secondary Option

**FCM HTTP v1 API** (raw HTTP requests) for:
- Full control over request/response handling
- Working in constrained environments
- Minimal dependencies
- Integration with custom auth flows

---

## Approach 1: Firebase Admin SDK for Dart

### Package Information

- **Package**: `firebase_admin_sdk`
- **Version**: 0.5.6 (as of April 2026)
- **Publisher**: firebase.google.com (verified)
- **Status**: Experimental release
- **URL**: https://pub.dev/packages/firebase_admin_sdk

### Features

✅ Fully supported services:
- **Messaging** (FCM Cloud Messaging)
- **Authentication**
- **Cloud Functions** (Cloud Tasks)
- **Cloud Firestore**
- **Cloud Storage**
- **App Check**
- **Security Rules**

### Installation

```yaml
# pubspec.yaml
dependencies:
  firebase_admin_sdk: ^0.5.6
```

### Usage Example

```dart
import 'package:firebase_admin_sdk/firebase_admin_sdk.dart';
import 'package:firebase_admin_sdk/messaging.dart';

void main() async {
  // Initialize Firebase App with service account credentials
  final app = FirebaseApp.initializeApp(
    AppOptions(
      credential: ServiceAccountCredential.fromJsonFile('path/to/serviceAccount.json'),
    ),
  );
  
  // Get Messaging instance
  final messaging = app.messaging();
  
  // Send to a specific device
  await messaging.send(
    TokenMessage(
      token: '<device-token>',
      notification: Notification(
        title: 'FCM Push Notification',
        body: 'This is a test notification',
      ),
      data: {'key': 'value'},
    ),
  );
  
  // Send to a topic
  await messaging.send(
    TopicMessage(
      topic: 'news',
      notification: Notification(
        title: 'Breaking News',
        body: 'Important updates',
      ),
    ),
  );
  
  // Send to multiple devices (multicast)
  await messaging.sendEachForMulticast(
    MulticastMessage(
      tokens: ['<token-1>', '<token-2>', '<token-3>'],
      notification: Notification(
        title: 'Batch Notification',
        body: 'Sent to multiple devices',
      ),
    ),
  );
}
```

### Message Types Supported

- **TokenMessage**: Send to device registration tokens
- **TopicMessage**: Send to topic subscriptions
- **ConditionMessage**: Send using complex condition statements
- **Batch send**: `sendEach()` - up to 500 messages in single call
- **Multicast**: `sendEachForMulticast()` - batch delivery to specific devices

---

## Approach 2: FCM HTTP v1 API (Raw Protocol)

### API Endpoint

**Endpoint**: `POST https://fcm.googleapis.com/v1/{parent=projects/*}/messages:send`

### Request Headers

```
Authorization: Bearer <OAuth2_access_token>
Content-Type: application/json
```

### Request Example

```http
POST https://fcm.googleapis.com/v1/projects/my-project-id/messages:send
Authorization: Bearer ya29.ElqKBGN2Ri_Uz...HnS_uNreA
Content-Type: application/json

{
  "message": {
    "token": "bk3RNwTe3H0:CI2k_HHwgIpoDKCIZvvDMExUdFQ3P1...",
    "notification": {
      "title": "FCM Message",
      "body": "This is a FCM notification message!",
      "android": {
        "notification": {
          "click_action": "FLUTTER_NOTIFICATION_CLICK"
        }
      },
      "apns": {
        "payload": {
          "aps": {
            "category": "NEW_NOTIFICATION"
          }
        }
      }
    }
  }
}
```

### Response Example

```json
{
  "name": "projects/my-project-id/messages/0:1500415314455276%31bd1c9631bd1c96"
}
```

### Dart Implementation Example

```dart
import 'dart:convert';
import 'dart:io';

import 'package:googleapis_auth/auth_io.dart';

class FcmService {
  final String projectId;
  
  FcmService({required this.projectId});
  
  /// Get OAuth2 access token from service account
  Future<String> _getAccessToken() async {
    try {
      final serviceAccountFile = 'path/to/service-account.json';
      final serviceAccount = await json.decode(
        File(serviceAccountFile).readAsString(),
      );
      
      final client = await clientViaServiceAccount(
        ServiceAccountCredentials.fromJson(serviceAccount),
        ['https://www.googleapis.com/auth/firebase.messaging'],
      );
      
      return client.credentials.accessToken.data;
    } catch (e) {
      throw Exception('Error getting access token: $e');
    }
  }
  
  /// Send notification to a single device
  Future<bool> sendNotification({
    required String token,
    required String title,
    required String body,
  }) async {
    final accessToken = await _getAccessToken();
    const fcmEndpoint = "https://fcm.googleapis.com/v1/projects/$projectId/messages:send";
    
    final url = Uri.parse(fcmEndpoint);
    final headers = {
      HttpHeaders.contentTypeHeader: 'application/json',
      'Authorization': 'Bearer $accessToken',
    };
    
    final reqBody = jsonEncode({
      "message": {
        "token": token,
        "notification": {
          "title": title,
          "body": body,
        },
        "android": {
          "notification": {
            "click_action": "FLUTTER_NOTIFICATION_CLICK",
          }
        },
        "apns": {
          "payload": {
            "aps": {"category": "NEW_NOTIFICATION"}
          }
        }
      }
    });
    
    try {
      final response = await http.post(
        url,
        headers: headers,
        body: reqBody,
      );
      
      if (response.statusCode == 200) {
        return true;
      } else {
        print('FCM Error: ${response.statusCode} ${response.body}');
        return false;
      }
    } catch (e) {
      print('FCM Error: $e');
      return false;
    }
  }
}
```

---

## Authentication & Authorization

### Required OAuth2 Scope

```
https://www.googleapis.com/auth/firebase.messaging
```

### Authentication Methods

#### 1. Service Account Credentials (Recommended)
- Download service account key JSON from Firebase Console
- Use in Dart code with `ServiceAccountCredential`
- Store in secure location (not in source control)

#### 2. Workload Identity (Alternative)
- Recommended for Google Cloud environments
- No private key files needed
- Credentials mounted automatically by GKE/App Engine/Cloud Run

#### 3. Application Default Credentials (ADC)
- Works on Cloud Run, App Engine, Firebase Functions
- `Credentials.applicationDefault()` handles discovery

### Cross-Project Authorization

Service account can be created in "sender project" while sending messages to "target project":

1. Enable FCM API in target project
2. Create service account in sender project
3. Grant service account "Firebase Cloud Messaging API Admin" role in target project
4. Use sender project's credentials to send to target project

---

## Credentials Storage Best Practices

### ✅ DO

- Store service account JSON in `.gitignore`
- Use environment variables to point to file location
- Mount as volume in Docker/Kubernetes (if containerized)
- Use Secret Manager (if production GCP)
- Never commit credentials to version control
- Use separate service account with minimal permissions (Firebase Cloud Messaging API Admin)

### ❌ DON'T

- Hardcode credentials in source code
- Commit JSON files to Git
- Use default Firebase service account (overprivileged)
- Share credentials across multiple unrelated projects
- Store in plain text environment variables (use encrypted/obfuscated)

### Example: Environment Variable Configuration

```bash
# .env file
FIREBASE_SERVICE_ACCOUNT_PATH=/app/config/serviceAccountKey.json
PROJECT_ID=my-firebase-project
```

```dart
// Load from environment
final serviceAccountPath = dotenv.get('FIREBASE_SERVICE_ACCOUNT_PATH');
```

---

## Token Lifetime & Refresh

### OAuth2 Access Token Expiration

- **Default lifetime**: 1 hour
- **Behavior**: SDK automatically refreshes before expiration
- **Error**: "invalid_grant" or "401 Unauthorized" after expiration

### SDK Token Management (firebase_admin_sdk)

The `firebase_admin_sdk` handles token refresh automatically:

```dart
// No manual token handling needed
final messaging = app.messaging();
await messaging.send(message); // SDK manages auth internally
```

### Manual Token Refresh (HTTP v1 API)

When using raw HTTP:

```dart
// Token expires after 1 hour - SDK caches and refreshes automatically
final client = await clientViaServiceAccount(
  ServiceAccountCredentials.fromJson(serviceAccount),
  ['https://www.googleapis.com/auth/firebase.messaging'],
);

// Refresh handled automatically between requests
final accessToken = client.credentials.accessToken.data;
```

### Best Practices

1. **Don't cache tokens** - let SDK handle it
2. **Implement retry logic** for token expiration
3. **Use exponential backoff** for transient errors
4. **Monitor quota**: 2000 messages/second, 100K/10s, 300K/100s, 1M/day

---

## Platform-Specific Configuration

### Android

- FCM SDK handles registration tokens automatically
- Use `FirebaseMessaging.getInstance().getToken()` to get token
- Send Android-specific payload for rich notifications:

```dart
"android": {
  "notification": {
    "click_action": "FLUTTER_NOTIFICATION_CLICK"
  },
  "data": {
    // Custom data payload
  }
}
```

### iOS (APNs)

- **Critical**: Upload APNs certificate/key to Firebase Console
- Requires iOS 10+ with APNs enabled
- APNs payload format differs from Android:

```dart
"apns": {
  "payload": {
    "aps": {
      "alert": "Notification message",
      "body": "Notification body",
      "sound": "default"
    }
  }
}
```

- For production: APNs SSL certificate
- For development: Development certificate or tokens

### Web Push (Optional)

```dart
"webpush": {
  "vapid": {
    "subject": "/your-email@example.com",
    "publicKey": "your-public-key"
  },
  "data": {
    // Custom data
  }
}
```

---

## Sample Implementation (Complete)

### Using Firebase Admin SDK (Recommended)

```dart
import 'dart:convert';
import 'package:firebase_admin_sdk/firebase_admin_sdk.dart';
import 'package:firebase_admin_sdk/messaging.dart';

class FcmService {
  late final FirebaseApp _app;
  late final Messaging _messaging;
  
  /// Initialize FCM service
  /// [serviceAccountFile]: Path to service account JSON file
  Future<void> initialize(String serviceAccountFile) async {
    final serviceAccount = json.decode(File(serviceAccountFile).readAsStringSync());
    
    _app = FirebaseApp.initializeApp(
      AppOptions(
        credential: ServiceAccountCredential.fromJson(serviceAccount),
      ),
    );
    
    _messaging = _app.messaging();
  }
  
  /// Send notification to single device
  Future<SendResponse> sendToDevice({
    required String deviceId,
    required String title,
    required String body,
    Map<String, dynamic>? data,
  }) async {
    return _messaging.send(
      TokenMessage(
        token: deviceId,
        notification: Notification(
          title: title,
          body: body,
        ),
        data: data,
      ),
    );
  }
  
  /// Send to topic
  Future<SendResponse> sendToTopic(String topic, {
    required String title,
    required String body,
  }) async {
    return _messaging.send(
      TopicMessage(
        topic: topic,
        notification: Notification(
          title: title,
          body: body,
        ),
      ),
    );
  }
  
  /// Send to multiple devices
  Future<BatchResponse> sendToDeviceList(List<String> deviceTokens, {
    required String title,
    required String body,
  }) async {
    return _messaging.sendEach([
      for (final token in deviceTokens)
        TokenMessage(
          token: token,
          notification: Notification(
            title: title,
            body: body,
          ),
        )
    ]);
  }
  
  /// Send multicast (single message to multiple tokens)
  Future<BatchResponse> sendMulticast({
    required List<String> tokens,
    required String title,
    required String body,
  }) async {
    return _messaging.sendEachForMulticast(
      MulticastMessage(
        tokens: tokens,
        notification: Notification(
          title: title,
          body: body,
        ),
      ),
    );
  }
  
  /// Subscribe tokens to topic
  Future<BatchResponse> subscribeTokensToTopic(
    List<String> tokens,
    String topic,
  ) async {
    return _messaging.subscribeToTopic(tokens, topic);
  }
  
  /// Unsubscribe tokens from topic
  Future<BatchResponse> unsubscribeTokensFromTopic(
    List<String> tokens,
    String topic,
  ) async {
    return _messaging.unsubscribeFromTopic(tokens, topic);
  }
}
```

---

## Security Considerations

### 1. Service Account Security

- **Principle of least privilege**: Use specific role (Firebase Cloud Messaging API Admin)
- **Never commit to Git**: Add `serviceAccountKey.json` to `.gitignore`
- **Rotate credentials** if compromised
- **Monitor usage** in Firebase Console

### 2. Network Security

- **Direct HTTPS**: FCM endpoint uses HTTPS
- **No public IP exposure**: Run bridge behind firewall/internal network
- **Rate limiting**: Implement to prevent abuse
- **Request signing**: Consider for additional validation

### 3. Production Deployment

```yaml
# Docker - Mount credentials as volume (not in image)
volumes:
  - /app/config/serviceAccountKey.json:/app/config/serviceAccountKey.json:ro
  - /var/run/docker.sock:/var/run/docker.sock
```

```bash
# Run with credential file path in environment
export FIREBASE_SERVICE_ACCOUNT_PATH=/app/config/serviceAccountKey.json
```

### 4. Error Handling

```dart
try {
  final response = await _messaging.send(message);
  print('Message sent: $response');
} on FirebaseException catch (e) {
  // Handle Firebase-specific errors
  if (e.code == 'quota-exceeded') {
    print('FCM quota exceeded');
  } else if (e.code == 'invalid-registration-token') {
    print('Invalid token - needs cleanup');
  }
} catch (e) {
  print('Unexpected error: $e');
}
```

---

## Quota & Rate Limits

FCM imposes the following limits:

| Metric | Limit | Window |
|--------|-------|--------|
| Messages/second | 2,000 | - |
| Messages/10 seconds | 100,000 | - |
| Messages/100 seconds | 300,000 | - |
| Messages/day | 1,000,000 | - |

### Quota Management

```dart
try {
  // Attempt to send message
  await messaging.send(message);
} on FirebaseException catch (e) {
  if (e.code == 'quota-exceeded') {
    // Wait before retrying (exponential backoff)
    await Future.delayed(Duration(seconds: 10));
    await messaging.send(message);
  }
}
```

---

## Migration Path

### From Legacy FCM to HTTP v1

**Before** (Legacy endpoint - deprecated):
```
POST https://fcm.googleapis.com/fcm/send
Authorization: key=<server_key>
```

**After** (HTTP v1 - current):
```
POST https://fcm.googleapis.com/v1/projects/<project-id>/messages:send
Authorization: Bearer <oauth2_access_token>
```

### Migration Timeline

- **Deprecation date**: June 20, 2023
- **Shutdown start**: July 22, 2024
- **Full shutdown**: Ongoing migration

---

## References

1. [Firebase Admin SDK for Dart - pub.dev](https://pub.dev/packages/firebase_admin_sdk)
2. [FCM HTTP v1 API - Firebase Docs](https://firebase.google.com/docs/cloud-messaging/send/v1-api)
3. [FCM Server-Side Send - Firebase Docs](https://firebase.google.com/docs/cloud-messaging/send)
4. [FCM Migration Guide - V1 API](https://firebase.google.com/docs/cloud-messaging/migrate-v1)
5. [Your server environment and FCM](https://firebase.google.com/docs/cloud-messaging/server)
6. [Firebase Admin SDK Release Notes](https://firebase.google.com/support/release-notes/admin/dart)

---

## Conclusion

For the **bridge process**, **Firebase Admin SDK for Dart** is the recommended approach due to:

1. ✅ Automatic token management
2. ✅ Type-safe Dart implementation
3. ✅ Production-ready (official Firebase SDK)
4. ✅ Lower error surface
5. ✅ Full FCM feature support

**FCM HTTP v1 API** is a viable alternative when:
- Minimal dependencies required
- Custom request handling needed
- Integration with existing auth infrastructure
- Lower-level control desired

Both approaches use **service account credentials** stored securely on the server and make **direct HTTPS calls to FCM** - no Cloudflare Access or special bridging infrastructure needed.
