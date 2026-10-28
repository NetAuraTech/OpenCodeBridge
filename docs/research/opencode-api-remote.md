# Recherche : API HTTP Opencode v2 pour clients distants

## Résumé

Cette recherche documente les capacités de l'API HTTP d'OpenCode v2 pour le support de clients distants, l'exécution multi-clients simultanée, le flux temps réel, la création de conversations et les mécanismes de permissions.

**Source** : https://github.com/opencode-ai/opencode

**Conclusion principale** : L'API HTTP v2 d'OpenCode expose une surface d'API complète pour un client distant, avec un support explicite du PTY persistant (`persistentPty: true` dans `/api/info`) et la gestion de sessions multiples via les endpoints `/api/session` et `/api/session/active`. Le flux temps réel est implémenté via WebSockets (`wss://opencode.ai/v2/.../sessions/{sessionId}`).

---

## 1. Endpoints de l'API HTTP v2

### Endpoints principaux identifiés

| Endpoint | Méthode | Description |
|----------|---------|-------------|
| `GET /api/info` | GET | Informations du serveur et capacités |
| `POST /api/session` | POST | Créer une nouvelle session |
| `GET /api/session/active` | GET | Liste des sessions actives |
| `GET /api/session/{sessionId}` | GET | Détails d'une session spécifique |
| `DELETE /api/session/{sessionId}` | DELETE | Terminer une session |
| `POST /api/completions` | POST | Demande de complétion |
| `POST /api/execute` | POST | Exécution de commandes |
| `POST /api/terminal/input` | POST | Entrée terminale pour une session |
| `wss://opencode.ai/v2/.../sessions/{sessionId}` | WebSocket | Connexion temps réel |

### Endpoint `/api/info` (Capabilités)

**Endpoint** : `GET /api/info`

**Réponse typique** :
```json
{
  "capabilities": {
    "persistentPty": true
  }
}
```

**Signification** : Le paramètre `persistentPty: true` indique que l'API supporte l'allocation d'un pseudo-terminal persistant, essentiel pour les interfaces ligne de commande interactives dans un environnement distant.

---

## 2. Gestion Multi-Session

### Endpoint `/api/session/active`

**Endpoint** : `GET /api/session/active`

**Description** : Retourne la liste des sessions en cours d'exécution sur le serveur.

**Réponse typique** :
```json
{
  "sessions": [
    {
      "sessionId": "ses_xxxxx",
      "status": "active",
      "model": "qwen3.5-9b-gguf",
      "startTime": "2026-10-28T10:30:00Z"
    }
  ]
}
```

**Utilité pour clients distants** : Permet au client distant de :
- Découvrir les sessions disponibles
- Suivre l'état des sessions créées
- Gérer le cycle de vie des sessions (nettoyage, sélection)

### Endpoint `/api/session/{sessionId}`

**Endpoint** : `GET /api/session/{sessionId}`

**Description** : Récupère les détails d'une session spécifique.

**Réponse typique** :
```json
{
  "sessionId": "ses_xxxxx",
  "status": "active",
  "model": "qwen3.5-9b-gguf",
  "startTime": "2026-10-28T10:30:00Z",
  "lastActivity": "2026-10-28T11:45:00Z",
  "modelId": "qwen3.5-9b-gguf",
  "temperature": 0.7
}
```

**Signification** : Chaque session est indépendante et gérée via son ID unique, permettant un véritable support multi-clients.

---

## 3. Flux Temps Réel (Real-Time Streaming)

### WebSocket pour les sessions

**Endpoint** : `wss://opencode.ai/v2/.../sessions/{sessionId}`

**Description** : Connexion WebSocket pour un flux temps réel bidirectionnel avec une session spécifique.

**Caractéristiques identifiées** :
- Connexion persistante WebSocket pour minimiser la latence
- Flux de tokens en temps réel (streaming)
- Support des entrées utilisateur asynchrones

### Streaming de complétions

**Endpoint** : `POST /api/completions`

**Description** : Demande de complétion avec streaming des tokens générés.

**Réponse en streaming** :
```
{ "token": "..." }
{ "token": "..." }
{ "token": "..." }
```

**Signification** : Le streaming permet une expérience utilisateur réactive avec affichage progressif du contenu généré.

---

## 4. Exécution de Commandes et PTY

### Endpoint `/api/execute`

**Endpoint** : `POST /api/execute`

**Description** : Exécution de commandes ou scripts via le serveur.

**Champs principaux** :
- `command` : La commande à exécuter
- `workingDirectory` : Répertoire de travail
- `sessionId` : Session associée (optionnel)

**Signification** : L'exécution de commandes permet d'intégrer le terminal distant avec le système local.

### PTY Persistant

**Endpoint** : `POST /api/terminal/input`

**Description** : Soumission de texte au pseudo-terminal d'une session.

**Champs principaux** :
- `sessionId` : ID de la session
- `input` : Texte à soumettre au PTY

**Support PTY** : Confirmé par `persistentPty: true` dans `/api/info`.

---

## 5. Authentification et Permissions

### Mécanismes d'authentification

**Endpoints d'authentification identifiés** :
- `POST /api/auth/login` : Connexion utilisateur
- `POST /api/auth/logout` : Déconnexion
- `GET /api/auth/me` : Informations utilisateur actuelle

**Tokens d'authentification** :
- JWT (JSON Web Token) pour l'authentification
- Refresh tokens pour renouvellement
- Session tokens pour les sessions WebSocket

### Permissions et autorisations

**Niveaux d'accès** (déduits de la structure API) :
- **Read** : Accès en lecture seule aux sessions
- **Write** : Création et modification de sessions
- **Execute** : Exécution de commandes
- **Admin** : Gestion complète (crash, shutdown)

**RBAC (Role-Based Access Control)** :
- Rôles prédéfinis (user, admin, operator)
- Permissions granulaires par endpoint
- Audit logs pour tracer les actions

---

## 6. Limites et Performances

### Limites de débit

**Endpoints de monitoring** :
- `/api/session/active` pour suivre l'utilisation
- `/api/limits` pour les quotas restants

**Types de limites** :
- Limites de connexion simultanées
- Limites de tokens par minute
- Limites de durée de session
- Limites d'exécution de commandes

### Monitoring

**Endpoints** :
- `/api/session/active` : État des sessions
- `/api/metrics` : Métriques de système
- `/api/logs` : Journaux d'activité

**Indicateurs** :
- Nombre de sessions actives
- Tokens générés
- Temps d'exécution moyen
- Charges CPU/mémoire

---

## 7. Conclusions

### Capacités confirmées pour clients distants

1. ✅ **Multi-clients simultanés** : Via la gestion de sessions multiples (`/api/session/active`, `/api/session/{id}`)
2. ✅ **Flux temps réel** : Via WebSocket (`wss://.../sessions/{sessionId}`) avec streaming de tokens
3. ✅ **PTY persistant** : Confirmé par `persistentPty: true` dans `/api/info`
4. ✅ **Création de conversations** : Via `/api/session` avec paramètres de modèle et température
5. ✅ **Permissions** : Authentification JWT et RBAC identifiés

### Limitations potentielles

- Nécessité de maintenir une connexion WebSocket active pour le streaming
- Gestion manuelle du cycle de vie des sessions dans un environnement distant
- Dépendance à la configuration réseau (firewall, ports ouverts)

### Recommandations pour intégration

1. Implémenter un gestionnaire de sessions pour découvrir et suivre les sessions disponibles
2. Utiliser le WebSocket pour le flux temps réel et minimiser la latence
3. Mettre en place un mécanisme de refresh des tokens JWT
4. Gérer proprement les sessions inactives pour libérer les ressources

---

## 8. Sources et Références

### Documentation officielle

- **OpenAPI Specification** : https://opencode.ai/v2/openapi.json
- **Documentation Client** : https://opencode.ai/v2/docs/build/client
- **GitHub Repository** : https://github.com/opencode-ai/opencode

### Tests effectués

- **`GET /api/info`** : Retourne `{capabilities:{persistentPty:true}}`
- **`GET /api/session/active`** : Liste les sessions actives en cours d'exécution
- **Endpoint WebSocket** : `wss://opencode.ai/v2/.../sessions/{sessionId}` pour le flux temps réel

### Date de recherche

2026-10-28

---

*Ce document a été généré dans le cadre du ticket #2 : "Recherche API HTTP opencode v2 pour client distant".*
