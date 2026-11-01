const GOOGLE_CLIENT_ID =
  "277143872615-coqt80r9nkb1okfefj6bvtvn8mdfou17.apps.googleusercontent.com";

const ADMIN_EMAIL =
  "thegrassrooter@gmail.com";

const STORAGE_PREFIX =
  "grassAI_user_";

const ACCOUNT_PREFIX =
  "grassAI_account_";

const SESSION_PREFIX =
  "grassAI_session_";

const EMAIL_INDEX_PREFIX =
  "grassAI_email_";

const CHAT_CHUNK_SIZE =
  7000;

const MAX_IMAGES =
  3;

const MAX_IMAGE_DATA_LENGTH =
  20 * 1024 * 1024;

/* =========================
   GRASS INTELLIGENCE ENGINE
   ========================= */

// Conservative budgets for Groq's shared on-demand token-per-minute limit.
// These are request-planning targets, not a guarantee of available org TPM.
const GRASS_TEXT_INPUT_BUDGET = 3500;
const GRASS_IMAGE_INPUT_BUDGET = 1200;
const GRASS_TEXT_OUTPUT_BUDGET = 1024;
const GRASS_IMAGE_OUTPUT_BUDGET = 768;
const GRASS_CHARS_PER_ESTIMATED_TOKEN = 3;
const GRASS_RECENT_MESSAGE_COUNT = 8;
const GRASS_MAX_RELEVANT_OLDER_MESSAGES = 6;

// Per-conversation message allowance; usage is stored server-side.
const GRASS_CHAT_MESSAGE_LIMIT = 15;
// Public grassNotch requests use the existing server-side GROQ_API_KEY.
// Configure this ceiling to match the deployment's acceptable daily spend.
const GRASSNOTCH_DAILY_REQUEST_LIMIT = 250;
// Vision requests are more expensive, so the public no-sign-in Notch route
// has a separate shared daily ceiling in addition to the overall request cap.
const GRASSNOTCH_DAILY_VISION_REQUEST_LIMIT = 50;
const GRASSNOTCH_MODEL = "grass2";
const GRASSNOTCH_MAX_IMAGE_DATA_LENGTH = 6 * 1024 * 1024;


/* =========================
   AUTH SETTINGS
   ========================= */

const SESSION_DURATION_MS =
  30 * 24 * 60 * 60 * 1000;

/*
 * Apps Script does not provide bcrypt
 * directly, so grassAI uses:
 *
 * - a unique random salt
 * - repeated SHA-256 hashing
 * - no plaintext password storage
 */
const PASSWORD_HASH_ITERATIONS =
  10000;

/* =========================
   MODEL SYSTEM
   ========================= */

const GRASSAI_MODELS = {
  grass1: {
    name: "grass1",
    premium: false,
    codingAllowed: false,
    visionAllowed: false,
    apiModel:
      "openai/gpt-oss-120b",
  },

  grass2: {
    name: "grass2",
    premium: true,
    codingAllowed: true,
    visionAllowed: true,
    apiModel:
      "openai/gpt-oss-120b",
    visionModel:
      "qwen/qwen3.8-27b",
  },
};

const DEFAULT_MODEL =
  "grass1";

/* =========================
   RESPONSE
   ========================= */

function jsonResponse(data) {
  return ContentService
    .createTextOutput(
      JSON.stringify(data)
    )
    .setMimeType(
      ContentService.MimeType.JSON
    );
}

/* =========================
   GET
   ========================= */

function doGet() {
  return jsonResponse({
    success: true,
    app: "grassAI",
    message:
      "Backend connected successfully",
  });
}

/* =========================
   POST ROUTER
   ========================= */

function doPost(e) {
  try {
    const action =
      e &&
      e.parameter
        ? e.parameter.action
        : null;

    if (action === "googleLogin") {
      return handleGoogleLogin(
        e.parameter.credential
      );
    }

    if (action === "emailSignUp") {
      return handleEmailSignUp(
        e.parameter.name,
        e.parameter.email,
        e.parameter.password
      );
    }

    if (action === "emailLogin") {
      return handleEmailLogin(
        e.parameter.email,
        e.parameter.password
      );
    }

    if (action === "getSubscription") {
      return handleGetSubscription(
        e.parameter.credential
      );
    }

    /* =========================
       grassWorkspace BASE
       Account-isolated document storage; independent from grassAI plans and memory.
       ========================= */
    if (action === "workspaceListDocuments") {
      return handleWorkspaceListDocuments(e.parameter.credential);
    }
    if (action === "workspaceLoadDocument") {
      return handleWorkspaceLoadDocument(e.parameter.credential, e.parameter.documentId);
    }
    if (action === "workspaceSaveDocument") {
      return handleWorkspaceSaveDocument(e.parameter.credential, e.parameter.document);
    }
    if (action === "workspaceRenameDocument") {
      return handleWorkspaceRenameDocument(e.parameter.credential, e.parameter.documentId, e.parameter.title);
    }
    if (action === "workspaceDeleteDocument") {
      return handleWorkspaceDeleteDocument(e.parameter.credential, e.parameter.documentId);
    }
    if (action === "workspaceWritingAssist") {
      return handleWorkspaceWritingAssist(e.parameter.credential, e.parameter.instruction, e.parameter.content);
    }

    if (action === "redeemPromo") {
      return handleRedeemPromo(
        e.parameter.credential,
        e.parameter.code
      );
    }

    if (action === "loadConversations") {
      return handleLoadConversations(
        e.parameter.credential
      );
    }

    if (action === "getChatUsage") {
      return handleGetChatUsage(
        e.parameter.credential,
        e.parameter.conversationId
      );
    }

    if (action === "saveConversations") {
      return handleSaveConversations(
        e.parameter.credential,
        e.parameter.conversations
      );
    }

    if (action === "loadChat") {
      return handleLoadChat(
        e.parameter.credential
      );
    }

    if (action === "saveChat") {
      return handleSaveChat(
        e.parameter.credential,
        e.parameter.messages
      );
    }

    if (action === "migrateChat") {
      return handleMigrateChat(
        e.parameter.credential,
        e.parameter.messages
      );
    }

    if (action === "chat") {
      return handleChat(
        e.parameter.message,
        e.parameter.history,
        e.parameter.credential,
        e.parameter.model,
        e.parameter.images,
        e.parameter.conversationId
      );
    }

    // Native grassNotch chat uses grass2 (vision when a screen image is sent)
    // without asking for a website account. Its public route is protected by
    // server-side overall and vision-specific daily request ceilings.
    if (action === "grassNotchChat") {
      return handleGrassNotchChat(
        e.parameter.message,
        e.parameter.history,
        e.parameter.clientId,
        e.parameter.conversationId,
        e.parameter.images
      );
    }

    /* =========================
       grassMemory
       These actions never call the AI provider.
       ========================= */

    if (action === "loadMemories") {
      return handleLoadMemories(
        e.parameter.credential
      );
    }

    if (action === "memoryCommand") {
      return handleMemoryCommand(
        e.parameter.credential,
        e.parameter.command
      );
    }

    /* =========================
       ADMIN ACTIONS
       ========================= */

    if (action === "adminGetUsers") {
      return handleAdminGetUsers(
        e.parameter.credential
      );
    }

    if (action === "adminRevokePremium") {
      return handleAdminRevokePremium(
        e.parameter.credential,
        e.parameter.accountId
      );
    }

    throw new Error(
      "Unknown action."
    );
  } catch (error) {
    return jsonResponse({
      success: false,
      error:
        error &&
        error.message
          ? error.message
          : "Unknown backend error.",
    });
  }
}

/* =========================
   GENERAL HASHING
   ========================= */

function bytesToHex(bytes) {
  return bytes
    .map(function (byte) {
      const value =
        byte < 0
          ? byte + 256
          : byte;

      return value
        .toString(16)
        .padStart(2, "0");
    })
    .join("");
}

function sha256Hex(value) {
  const digest =
    Utilities.computeDigest(
      Utilities.DigestAlgorithm.SHA_256,
      String(value || "")
    );

  return bytesToHex(
    digest
  );
}

/* =========================
   GOOGLE AUTH
   ========================= */

function verifyGoogleToken(idToken) {
  if (!idToken) {
    throw new Error(
      "Google ID token is required."
    );
  }

  const response =
    UrlFetchApp.fetch(
      "https://oauth2.googleapis.com/tokeninfo?id_token=" +
        encodeURIComponent(idToken),
      {
        method: "get",
        muteHttpExceptions: true,
      }
    );

  const statusCode =
    response.getResponseCode();

  const responseText =
    response.getContentText();

  if (statusCode !== 200) {
    throw new Error(
      "Google token verification failed."
    );
  }

  let googleUser;

  try {
    googleUser =
      JSON.parse(
        responseText
      );
  } catch (error) {
    throw new Error(
      "Google returned an invalid token response."
    );
  }

  if (
    googleUser.aud !==
    GOOGLE_CLIENT_ID
  ) {
    throw new Error(
      "Google token audience does not match grassAI."
    );
  }

  if (
    googleUser.iss !==
      "accounts.google.com" &&
    googleUser.iss !==
      "https://accounts.google.com"
  ) {
    throw new Error(
      "Invalid Google token issuer."
    );
  }

  if (!googleUser.sub) {
    throw new Error(
      "Google account ID is missing."
    );
  }

  if (
    googleUser.email_verified !==
      "true" &&
    googleUser.email_verified !==
      true
  ) {
    throw new Error(
      "Google email is not verified."
    );
  }

  if (
    !googleUser.email ||
    !validateEmail(
      normalizeEmail(
        googleUser.email
      )
    )
  ) {
    throw new Error(
      "Google account email is invalid."
    );
  }

  return googleUser;
}

/* =========================
   ACCOUNT STORAGE
   ========================= */

function getAccountKey(googleUser) {
  return (
    STORAGE_PREFIX +
    sha256Hex(
      googleUser.sub
    )
  );
}

function getAccountId(googleUser) {
  return sha256Hex(
    googleUser.sub
  );
}

function getEmailAccountId(email) {
  const normalized =
    normalizeEmail(email);

  return sha256Hex(
    "email:" +
      normalized
  );
}

function getEmailAccountKey(email) {
  return (
    STORAGE_PREFIX +
    getEmailAccountId(
      email
    )
  );
}

function getAccountRecordKey(
  accountId
) {
  return (
    ACCOUNT_PREFIX +
    accountId
  );
}

function getProperties() {
  return PropertiesService
    .getScriptProperties();
}

function getMetaKey(accountKey) {
  return (
    accountKey +
    "_meta"
  );
}

function getChunkKey(
  accountKey,
  index
) {
  return (
    accountKey +
    "_chat_" +
    index
  );
}

/* =========================
   ACCOUNT REGISTRY
   ========================= */

function getAccountRecord(
  accountId
) {
  const raw =
    getProperties().getProperty(
      getAccountRecordKey(
        accountId
      )
    );

  if (!raw) {
    return null;
  }

  try {
    return JSON.parse(raw);
  } catch (error) {
    throw new Error(
      "grassAI account data is corrupted."
    );
  }
}

function saveAccountRecord(
  accountId,
  record
) {
  getProperties().setProperty(
    getAccountRecordKey(
      accountId
    ),
    JSON.stringify(record)
  );
}

/* =========================
   EMAIL SYSTEM
   ========================= */

function normalizeEmail(email) {
  return String(
    email || ""
  )
    .trim()
    .toLowerCase();
}

function validateEmail(email) {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(
    email
  );
}

function getEmailIndexKey(email) {
  return (
    EMAIL_INDEX_PREFIX +
    sha256Hex(
      normalizeEmail(
        email
      )
    )
  );
}

function getIndexedAccountId(
  email
) {
  const normalizedEmail =
    normalizeEmail(email);

  if (!normalizedEmail) {
    return null;
  }

  return (
    getProperties().getProperty(
      getEmailIndexKey(
        normalizedEmail
      )
    ) || null
  );
}

function setEmailIndex(
  email,
  accountId
) {
  getProperties().setProperty(
    getEmailIndexKey(
      email
    ),
    accountId
  );
}

/*
 * Finds an account by email.
 *
 * The email index is checked first.
 * The full account registry is used as
 * a fallback for older accounts created
 * before the email-index system existed.
 */
function findAccountByEmail(
  email
) {
  const normalizedEmail =
    normalizeEmail(email);

  if (!normalizedEmail) {
    return null;
  }

  const indexedAccountId =
    getIndexedAccountId(
      normalizedEmail
    );

  if (indexedAccountId) {
    const indexedAccount =
      getAccountRecord(
        indexedAccountId
      );

    if (
      indexedAccount &&
      normalizeEmail(
        indexedAccount.email
      ) === normalizedEmail
    ) {
      return indexedAccount;
    }
  }

  const properties =
    getProperties();

  const allProperties =
    properties.getProperties();

  for (
    const key in allProperties
  ) {
    if (
      !key.startsWith(
        ACCOUNT_PREFIX
      )
    ) {
      continue;
    }

    try {
      const account =
        JSON.parse(
          allProperties[key]
        );

      if (
        account &&
        normalizeEmail(
          account.email
        ) ===
          normalizedEmail
      ) {
        /*
         * Repair the index for old
         * accounts automatically.
         */
        if (
          account.id
        ) {
          setEmailIndex(
            normalizedEmail,
            account.id
          );
        }

        return account;
      }
    } catch (error) {
      /*
       * Ignore malformed unrelated
       * account records.
       */
    }
  }

  return null;
}

/* =========================
   GOOGLE ACCOUNT CREATION
   ========================= */

function createOrUpdateAccount(
  googleUser
) {
  const accountId =
    getAccountId(
      googleUser
    );

  const normalizedEmail =
    normalizeEmail(
      googleUser.email
    );

  /*
   * Check the global email registry first.
   *
   * If this email belongs to an email/password
   * account, Google must NOT create another
   * account with the same email.
   */
  const existingByEmail =
    findAccountByEmail(
      normalizedEmail
    );

  if (
    existingByEmail &&
    existingByEmail.id !==
      accountId
  ) {
    throw new Error(
      "An account with this email already exists. Please sign in using email and password."
    );
  }

  const existing =
    getAccountRecord(
      accountId
    );

  /*
   * If an account with this Google ID exists,
   * continue using it and preserve Premium.
   */
  const now =
    new Date().toISOString();

  const record = {
    id:
      accountId,

    email:
      normalizedEmail,

    name:
      googleUser.name ||
      (existing
        ? existing.name
        : ""),

    picture:
      googleUser.picture ||
      (existing
        ? existing.picture
        : ""),

    provider:
      "google",

    createdAt:
      existing &&
      existing.createdAt
        ? existing.createdAt
        : now,

    updatedAt:
      now,

    subscription:
      existing &&
      existing.subscription ===
        "premium"
        ? "premium"
        : "free",
  };

  saveAccountRecord(
    accountId,
    record
  );

  /*
   * Register the email globally.
   */
  setEmailIndex(
    normalizedEmail,
    accountId
  );

  return record;
}

/* =========================
   PASSWORD SYSTEM
   ========================= */

function generateSalt() {
  return Utilities
    .getUuid()
    .replace(
      /-/g,
      ""
    );
}

function hashPassword(
  password,
  salt
) {
  let value =
    String(salt) +
    ":" +
    String(password);

  for (
    let i = 0;
    i < PASSWORD_HASH_ITERATIONS;
    i++
  ) {
    const digest =
      Utilities.computeDigest(
        Utilities.DigestAlgorithm.SHA_256,
        value
      );

    value =
      bytesToHex(
        digest
      );
  }

  return value;
}

function createPasswordRecord(
  password
) {
  const salt =
    generateSalt();

  return {
    salt:
      salt,

    hash:
      hashPassword(
        password,
        salt
      ),

    iterations:
      PASSWORD_HASH_ITERATIONS,
  };
}

function verifyPassword(
  password,
  passwordRecord
) {
  if (
    !passwordRecord ||
    !passwordRecord.salt ||
    !passwordRecord.hash
  ) {
    return false;
  }

  const iterations =
    Number(
      passwordRecord.iterations ||
        PASSWORD_HASH_ITERATIONS
    );

  let value =
    String(
      passwordRecord.salt
    ) +
    ":" +
    String(password);

  for (
    let i = 0;
    i < iterations;
    i++
  ) {
    const digest =
      Utilities.computeDigest(
        Utilities.DigestAlgorithm.SHA_256,
        value
      );

    value =
      bytesToHex(
        digest
      );
  }

  /*
   * Constant-time comparison.
   */
  if (
    value.length !==
    passwordRecord.hash.length
  ) {
    return false;
  }

  let difference = 0;

  for (
    let i = 0;
    i < value.length;
    i++
  ) {
    difference |=
      value.charCodeAt(i) ^
      passwordRecord.hash.charCodeAt(
        i
      );
  }

  return difference === 0;
}

/* =========================
   EMAIL ACCOUNT CREATION
   ========================= */

function createEmailAccount(
  name,
  email,
  password
) {
  const normalizedEmail =
    normalizeEmail(email);

  /*
   * The email index + registry scan are
   * both checked before account creation.
   */
  const existingByEmail =
    findAccountByEmail(
      normalizedEmail
    );

  if (existingByEmail) {
    throw new Error(
      "An account with this email already exists. Please sign in instead."
    );
  }

  const accountId =
    getEmailAccountId(
      normalizedEmail
    );

  const existingById =
    getAccountRecord(
      accountId
    );

  if (existingById) {
    throw new Error(
      "An account with this email already exists. Please sign in instead."
    );
  }

  const now =
    new Date().toISOString();

  const record = {
    id:
      accountId,

    email:
      normalizedEmail,

    name:
      String(name || "")
        .trim(),

    picture:
      "",

    provider:
      "email",

    createdAt:
      now,

    updatedAt:
      now,

    subscription:
      "free",

    password:
      createPasswordRecord(
        password
      ),
  };

  saveAccountRecord(
    accountId,
    record
  );

  /*
   * Register the email only after the
   * account record has been successfully
   * created.
   */
  setEmailIndex(
    normalizedEmail,
    accountId
  );

  return record;
}

/* =========================
   SESSION SYSTEM
   ========================= */

function generateSessionToken() {
  return (
    Utilities.getUuid() +
    "-" +
    Utilities.getUuid()
  ).replace(
    /-/g,
    ""
  );
}

function hashSessionToken(
  token
) {
  return sha256Hex(
    token
  );
}

function getSessionKey(
  tokenHash
) {
  return (
    SESSION_PREFIX +
    tokenHash
  );
}

function createSession(
  account
) {
  const token =
    generateSessionToken();

  const tokenHash =
    hashSessionToken(
      token
    );

  const now =
    Date.now();

  const session = {
    accountId:
      account.id,

    createdAt:
      now,

    expiresAt:
      now +
      SESSION_DURATION_MS,
  };

  getProperties().setProperty(
    getSessionKey(
      tokenHash
    ),
    JSON.stringify(session)
  );

  /*
   * Only the raw token is returned to the
   * frontend. The backend stores its hash.
   */
  return token;
}

function getSession(
  token
) {
  if (!token) {
    return null;
  }

  const tokenHash =
    hashSessionToken(
      token
    );

  const key =
    getSessionKey(
      tokenHash
    );

  const raw =
    getProperties().getProperty(
      key
    );

  if (!raw) {
    return null;
  }

  let session;

  try {
    session =
      JSON.parse(raw);
  } catch (error) {
    getProperties()
      .deleteProperty(
        key
      );

    return null;
  }

  if (
    !session.expiresAt ||
    Date.now() >=
      Number(
        session.expiresAt
      )
  ) {
    getProperties()
      .deleteProperty(
        key
      );

    return null;
  }

  const account =
    getAccountRecord(
      session.accountId
    );

  if (!account) {
    getProperties()
      .deleteProperty(
        key
      );

    return null;
  }

  return {
    session:
      session,

    account:
      account,
  };
}

/* =========================
   PUBLIC USER
   ========================= */

function getPublicUser(
  account
) {
  return {
    id:
      account.id,

    email:
      account.email || "",

    name:
      account.name || "",

    picture:
      account.picture || "",

    subscription:
      account.subscription ===
      "premium"
        ? "premium"
        : "free",

    isAdmin:
      isAdminAccount(
        account
      ),
  };
}

/* =========================
   UNIFIED AUTHENTICATION
   ========================= */

/*
 * Accepts either:
 *
 * 1. Google ID token
 * 2. grassAI email session token
 */
function authenticateCredential(
  credential
) {
  if (!credential) {
    throw new Error(
      "Authentication is required."
    );
  }

  /*
   * Email/password session.
   */
  const session =
    getSession(
      credential
    );

  if (session) {
    return {
      type:
        "session",

      account:
        session.account,
    };
  }

  /*
   * Otherwise verify as a Google ID token.
   */
  const googleUser =
    verifyGoogleToken(
      credential
    );

  const account =
    createOrUpdateAccount(
      googleUser
    );

  return {
    type:
      "google",

    googleUser:
      googleUser,

    account:
      account,
  };
}

/* =========================
   EMAIL SIGN UP
   ========================= */

function handleEmailSignUp(
  name,
  email,
  password
) {
  const cleanName =
    String(name || "")
      .trim();

  const cleanEmail =
    normalizeEmail(email);

  if (!cleanName) {
    throw new Error(
      "Please enter your name."
    );
  }

  if (!cleanEmail) {
    throw new Error(
      "Please enter your email address."
    );
  }

  if (!validateEmail(cleanEmail)) {
    throw new Error(
      "Please enter a valid email address."
    );
  }

  if (!password) {
    throw new Error(
      "Please enter a password."
    );
  }

  if (
    password.length < 8
  ) {
    throw new Error(
      "Your password must be at least 8 characters long."
    );
  }

  /*
   * Lock the complete signup operation.
   *
   * This prevents two simultaneous signup
   * requests from both passing the duplicate
   * email check.
   */
  const lock =
    LockService.getScriptLock();

  lock.waitLock(10000);

  try {
    const account =
      createEmailAccount(
        cleanName,
        cleanEmail,
        password
      );

    const token =
      createSession(
        account
      );

    return jsonResponse({
      success: true,

      user:
        getPublicUser(
          account
        ),

      token:
        token,
    });
  } finally {
    lock.releaseLock();
  }
}

/* =========================
   EMAIL LOGIN
   ========================= */

function handleEmailLogin(
  email,
  password
) {
  const cleanEmail =
    normalizeEmail(email);

  if (!cleanEmail) {
    throw new Error(
      "Please enter your email address."
    );
  }

  if (!validateEmail(cleanEmail)) {
    throw new Error(
      "Please enter a valid email address."
    );
  }

  if (!password) {
    throw new Error(
      "Please enter your password."
    );
  }

  const account =
    findAccountByEmail(
      cleanEmail
    );

  if (!account) {
    throw new Error(
      "Incorrect email or password."
    );
  }

  /*
   * Google-only accounts do not have a
   * password record.
   */
  if (
    account.provider !==
      "email" ||
    !account.password
  ) {
    throw new Error(
      "This account uses Google sign-in. Please continue with Google."
    );
  }

  const valid =
    verifyPassword(
      password,
      account.password
    );

  if (!valid) {
    throw new Error(
      "Incorrect email or password."
    );
  }

  account.updatedAt =
    new Date().toISOString();

  saveAccountRecord(
    account.id,
    account
  );

  const token =
    createSession(
      account
    );

  return jsonResponse({
    success: true,

    user:
      getPublicUser(
        account
      ),

    token:
      token,
  });
}

/* =========================
   SUBSCRIPTION
   ========================= */

function getSubscriptionForAccount(
  account
) {
  if (!account) {
    return "free";
  }

  return account.subscription ===
    "premium"
    ? "premium"
    : "free";
}

/* =========================
   ADMIN AUTHORIZATION
   ========================= */

function isAdminAccount(
  account
) {
  if (!account) {
    return false;
  }

  return (
    normalizeEmail(
      account.email
    ) ===
    ADMIN_EMAIL.toLowerCase()
  );
}

function requireAdmin(
  credential
) {
  const auth =
    authenticateCredential(
      credential
    );

  /*
   * Admin access is intentionally
   * Google-only.
   *
   * Even if someone somehow created an
   * email/password account using the admin
   * email, it cannot access the admin panel.
   */
  if (
    auth.type !==
    "google"
  ) {
    throw new Error(
      "Administrator access requires Google sign-in."
    );
  }

  if (
    !isAdminAccount(
      auth.account
    )
  ) {
    throw new Error(
      "Administrator access is required."
    );
  }

  return auth;
}

/* =========================
   GOOGLE LOGIN
   ========================= */

function handleGoogleLogin(
  idToken
) {
  const googleUser =
    verifyGoogleToken(
      idToken
    );

  /*
   * createOrUpdateAccount() performs the
   * global email uniqueness check.
   */
  const account =
    createOrUpdateAccount(
      googleUser
    );

  /*
   * The frontend already keeps the original
   * Google credential, so no custom session
   * token is needed for Google accounts.
   */
  return jsonResponse({
    success: true,

    user:
      getPublicUser(
        account
      ),
  });
}

/* =========================
   GET SUBSCRIPTION
   ========================= */

function handleGetSubscription(
  credential
) {
  const auth =
    authenticateCredential(
      credential
    );

  const account =
    auth.account;

  const premium =
    account.subscription ===
    "premium";

  return jsonResponse({
    success: true,

    subscription:
      premium
        ? "premium"
        : "free",

    isAdmin:
      isAdminAccount(
        account
      ),

    user:
      getPublicUser(
        account
      ),
  });
}

/* =========================
   PROMO CODES
   ========================= */

function normalizePromoCode(
  code
) {
  return String(
    code || ""
  )
    .trim()
    .toUpperCase();
}

function handleRedeemPromo(
  credential,
  code
) {
  const auth =
    authenticateCredential(
      credential
    );

  const account =
    auth.account;

  const normalizedCode =
    normalizePromoCode(
      code
    );

  if (!normalizedCode) {
    throw new Error(
      "Please enter a promo code."
    );
  }

  const PROMO_CODES = {
    GRASS2: "premium",
  };

  const reward =
    PROMO_CODES[
      normalizedCode
    ];

  if (!reward) {
    throw new Error(
      "Invalid promo code."
    );
  }

  if (
    reward === "premium"
  ) {
    account.subscription =
      "premium";

    account.updatedAt =
      new Date().toISOString();

    saveAccountRecord(
      account.id,
      account
    );

    return jsonResponse({
      success: true,

      message:
        "Premium unlocked successfully.",

      subscription:
        "premium",

      user: {
        id:
          account.id,

        email:
          account.email,

        subscription:
          "premium",
      },
    });
  }

  throw new Error(
    "This promo code has no valid reward."
  );
}

/* =========================
   grassWorkspace BASE
   Core document storage. Each account has its own index and document keys.
   Content is chunked to stay below Apps Script property value limits.
   ========================= */

const GRASS_WORKSPACE_INDEX_PREFIX = "grassWorkspace_docs_";
const GRASS_WORKSPACE_DOCUMENT_PREFIX = "grassWorkspace_doc_";
const GRASS_WORKSPACE_MAX_DOCUMENTS = 30;
const GRASS_WORKSPACE_MAX_CONTENT_LENGTH = 60000;
const GRASS_WORKSPACE_CHUNK_LENGTH = 1800;

function workspaceAccountKey(account) {
  return String(account.id).replace(/[^a-zA-Z0-9_-]/g, "_");
}

function workspaceIndexKey(account) {
  return GRASS_WORKSPACE_INDEX_PREFIX + workspaceAccountKey(account);
}

function workspaceDocumentPrefix(account, documentId) {
  return GRASS_WORKSPACE_DOCUMENT_PREFIX + workspaceAccountKey(account) + "_" + documentId;
}

function workspaceReadIndex(account) {
  const raw = getProperties().getProperty(workspaceIndexKey(account));
  if (!raw) return [];
  try {
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed : [];
  } catch (error) {
    throw new Error("Workspace document index is corrupted.");
  }
}

function workspaceWriteIndex(account, index) {
  getProperties().setProperty(workspaceIndexKey(account), JSON.stringify(index));
}

function workspaceValidateDocumentId(value) {
  const id = String(value || "");
  if (!/^[a-zA-Z0-9_-]{1,80}$/.test(id)) throw new Error("Invalid document identifier.");
  return id;
}

function workspaceLoadDocumentRecord(account, documentId) {
  const id = workspaceValidateDocumentId(documentId);
  const prefix = workspaceDocumentPrefix(account, id);
  const rawMeta = getProperties().getProperty(prefix + "_meta");
  if (!rawMeta) throw new Error("Document not found in this account.");
  let meta;
  try { meta = JSON.parse(rawMeta); } catch (error) { throw new Error("Document metadata is corrupted."); }
  let content = "";
  for (let i = 0; i < Number(meta.chunkCount || 0); i++) {
    const chunk = getProperties().getProperty(prefix + "_chunk_" + i);
    if (chunk === null) throw new Error("Document content is incomplete. Please retry loading it.");
    content += chunk;
  }
  return { id: id, title: String(meta.title || "Untitled document"), content: content, createdAt: meta.createdAt || "", updatedAt: meta.updatedAt || "" };
}

function handleWorkspaceListDocuments(credential) {
  const auth = authenticateCredential(credential);
  const index = workspaceReadIndex(auth.account);
  const properties = getProperties();
  return jsonResponse({ success: true, plan: "base", documents: index.map(function (doc) {
    const rawMeta = properties.getProperty(workspaceDocumentPrefix(auth.account, doc.id) + "_meta");
    let meta = {};
    if (rawMeta) { try { meta = JSON.parse(rawMeta); } catch (ignored) {} }
    return { id: doc.id, title: meta.title || "Untitled document", createdAt: meta.createdAt || doc.createdAt || "", updatedAt: meta.updatedAt || doc.updatedAt || "", characterCount: Number(doc.characterCount || 0) };
  }) });
}

function handleWorkspaceLoadDocument(credential, documentId) {
  const auth = authenticateCredential(credential);
  const id = workspaceValidateDocumentId(documentId);
  const index = workspaceReadIndex(auth.account);
  if (!index.some(function (doc) { return doc.id === id; })) throw new Error("Document not found in this account.");
  return jsonResponse({ success: true, document: workspaceLoadDocumentRecord(auth.account, id) });
}

function handleWorkspaceSaveDocument(credential, documentJson) {
  const auth = authenticateCredential(credential);
  let input;
  try { input = typeof documentJson === "string" ? JSON.parse(documentJson) : documentJson; }
  catch (error) { throw new Error("Invalid document payload."); }
  if (!input || typeof input !== "object") throw new Error("Invalid document payload.");
  const id = workspaceValidateDocumentId(input.id);
  const title = String(input.title || "Untitled document").trim().slice(0, 120) || "Untitled document";
  const content = String(input.content || "");
  if (content.length > GRASS_WORKSPACE_MAX_CONTENT_LENGTH) throw new Error("This document is too long for Workspace Base. Please split it into multiple documents.");
  const account = auth.account;
  const index = workspaceReadIndex(account);
  const existingMeta = index.find(function (doc) { return doc.id === id; });
  const prefix = workspaceDocumentPrefix(account, id);
  const oldMetaRaw = getProperties().getProperty(prefix + "_meta");
  let oldChunkCount = 0;
  if (oldMetaRaw) {
    try { oldChunkCount = Number(JSON.parse(oldMetaRaw).chunkCount || 0); } catch (ignored) {}
  }
  if (!existingMeta && index.length >= GRASS_WORKSPACE_MAX_DOCUMENTS) throw new Error("Workspace Base currently supports up to " + GRASS_WORKSPACE_MAX_DOCUMENTS + " documents per account.");
  const chunks = [];
  for (let offset = 0; offset < content.length; offset += GRASS_WORKSPACE_CHUNK_LENGTH) chunks.push(content.slice(offset, offset + GRASS_WORKSPACE_CHUNK_LENGTH));
  const now = new Date().toISOString();
  const record = {
    id: id,
    title: title,
    createdAt: existingMeta && existingMeta.createdAt ? existingMeta.createdAt : now,
    updatedAt: now,
    chunkCount: chunks.length,
  };
  const properties = getProperties();
  for (let i = 0; i < chunks.length; i++) properties.setProperty(prefix + "_chunk_" + i, chunks[i]);
  for (let i = chunks.length; i < oldChunkCount; i++) properties.deleteProperty(prefix + "_chunk_" + i);
  properties.setProperty(prefix + "_meta", JSON.stringify(record));
  // Keep the account index compact; titles live in each document's metadata property.
  const nextMeta = { id: id, createdAt: record.createdAt, updatedAt: now, characterCount: content.length };
  const nextIndex = existingMeta ? index.map(function (doc) { return doc.id === id ? nextMeta : doc; }) : [nextMeta].concat(index);
  workspaceWriteIndex(account, nextIndex);
  return jsonResponse({ success: true, document: { id: id, title: title, createdAt: record.createdAt, updatedAt: now, characterCount: content.length } });
}

function handleWorkspaceRenameDocument(credential, documentId, titleValue) {
  const auth = authenticateCredential(credential);
  const id = workspaceValidateDocumentId(documentId);
  const title = String(titleValue || "Untitled document").trim().slice(0, 120) || "Untitled document";
  const account = auth.account;
  const index = workspaceReadIndex(account);
  const existing = index.find(function (doc) { return doc.id === id; });
  if (!existing) throw new Error("Document not found in this account.");
  const properties = getProperties();
  const metaKey = workspaceDocumentPrefix(account, id) + "_meta";
  const rawMeta = properties.getProperty(metaKey);
  if (!rawMeta) throw new Error("Document not found in this account.");
  let meta;
  try { meta = JSON.parse(rawMeta); } catch (error) { throw new Error("Document metadata is corrupted."); }
  meta.title = title;
  meta.updatedAt = new Date().toISOString();
  properties.setProperty(metaKey, JSON.stringify(meta));
  workspaceWriteIndex(account, index.map(function (doc) {
    return doc.id === id ? Object.assign({}, doc, { updatedAt: meta.updatedAt }) : doc;
  }));
  return jsonResponse({ success: true, document: { id: id, title: title, createdAt: meta.createdAt || "", updatedAt: meta.updatedAt } });
}

function handleWorkspaceDeleteDocument(credential, documentId) {
  const auth = authenticateCredential(credential);
  const id = workspaceValidateDocumentId(documentId);
  const index = workspaceReadIndex(auth.account);
  const existing = index.find(function (doc) { return doc.id === id; });
  if (!existing) throw new Error("Document not found in this account.");
  const prefix = workspaceDocumentPrefix(auth.account, id);
  const rawMeta = getProperties().getProperty(prefix + "_meta");
  let chunkCount = 0;
  if (rawMeta) { try { chunkCount = Number(JSON.parse(rawMeta).chunkCount || 0); } catch (ignored) {} }
  const properties = getProperties();
  for (let i = 0; i < chunkCount; i++) properties.deleteProperty(prefix + "_chunk_" + i);
  properties.deleteProperty(prefix + "_meta");
  workspaceWriteIndex(auth.account, index.filter(function (doc) { return doc.id !== id; }));
  return jsonResponse({ success: true, deleted: true, documentId: id });
}

function handleWorkspaceWritingAssist(credential, instructionValue, contentValue) {
  const auth = authenticateCredential(credential);
  const instruction = String(instructionValue || "").trim();
  const content = String(contentValue || "");
  if (!instruction) throw new Error("Please describe the writing change you want.");
  if (instruction.length > 1200) throw new Error("Please shorten your writing instruction to 1,200 characters or fewer.");
  if (content.length > 12000) throw new Error("Please select or provide a section of 12,000 characters or fewer.");
  if (/\b(summarize|summarise|summary|edit text)\b/i.test(instruction)) {
    throw new Error("That tool is reserved for grassWorkspace Pro. Try a different writing instruction in Base.");
  }
  const apiKey = PropertiesService.getScriptProperties().getProperty("GROQ_API_KEY");
  if (!apiKey) throw new Error("The writing assistant is not configured yet.");
  const systemPrompt = "You are grassWorkspace Writing Tools, an AI writing assistant for the free Base tier. Follow the user's specific writing instruction and return only the finished text, without commentary, quotation marks, headings about your process, or Markdown fences unless the requested output itself needs them. Preserve the user's facts, intent, and meaning. Do not invent details. Do not perform summarisation or the dedicated Edit Text feature; those are Pro-only. If the instruction asks for a summary, ask for a different instruction instead. If the content is empty, compose a new draft based on the instruction. This tool is for writing assistance, not programming code.";
  const userPrompt = "INSTRUCTION:\n" + instruction + "\n\nTEXT TO WORK ON:\n" + (content || "[No existing text. Compose a draft from the instruction.]" );
  const response = UrlFetchApp.fetch("https://api.groq.com/openai/v1/chat/completions", {
    method: "post",
    contentType: "application/json",
    headers: { Authorization: "Bearer " + apiKey },
    payload: JSON.stringify({
      model: GRASSAI_MODELS.grass1.apiModel,
      messages: [ { role: "system", content: systemPrompt }, { role: "user", content: userPrompt } ],
      max_completion_tokens: 1600,
    }),
    muteHttpExceptions: true,
  });
  const statusCode = response.getResponseCode();
  const responseText = response.getContentText();
  if (statusCode < 200 || statusCode >= 300) {
    if (statusCode === 413 || /rate_limit_exceeded|tokens per minute|TPM/i.test(responseText)) {
      throw new Error("The shared AI rate limit has been reached. Please wait a little and try again.");
    }
    throw new Error("Writing assistant error (" + statusCode + "): " + responseText.slice(0, 500));
  }
  let data;
  try { data = JSON.parse(responseText); } catch (error) { throw new Error("The writing assistant returned an invalid response."); }
  const text = data && data.choices && data.choices[0] && data.choices[0].message && data.choices[0].message.content;
  if (!text || !String(text).trim()) throw new Error("The writing assistant returned no text. Please try again.");
  return jsonResponse({ success: true, model: "grass1", text: String(text).trim(), plan: "base" });
}

/* =========================
   grassMemory
   Deterministic account-isolated memory storage.
   Memory operations do not call Groq or any model.
   ========================= */

const GRASS_MEMORY_PREFIX = "grassAI_memory_";
const GRASS_MEMORY_MAX_ITEMS = 40;
const GRASS_MEMORY_MAX_TEXT_LENGTH = 500;

function getMemoryStorageKey(account) {
  // account.id is unique for both Google and email accounts.
  return GRASS_MEMORY_PREFIX + String(account.id);
}

function readAccountMemories(account) {
  const raw = loadRawStorage(getMemoryStorageKey(account));
  if (!raw) return [];
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (error) {
    throw new Error("Your Memory Garden data could not be read.");
  }
  if (!Array.isArray(parsed)) return [];
  return parsed
    .filter((item) => item && typeof item.id === "string" && typeof item.text === "string")
    .slice(0, GRASS_MEMORY_MAX_ITEMS);
}

function writeAccountMemories(account, memories) {
  saveRawStorage(
    getMemoryStorageKey(account),
    JSON.stringify(memories.slice(0, GRASS_MEMORY_MAX_ITEMS))
  );
}

function normalizeMemoryText(value) {
  return String(value || "")
    .replace(/\s+/g, " ")
    .trim()
    .replace(/[.!?]+$/, "");
}

function memoryWords(value) {
  return normalizeMemoryText(value)
    .toLowerCase()
    .replace(/[^a-z0-9\s]/g, " ")
    .split(/\s+/)
    .filter((word) => word.length > 2 && !["the", "and", "for", "that", "with", "from", "about", "your", "my", "our", "this", "old", "previous", "former", "saved"].includes(word));
}

function parseGrassMemoryCommand(command) {
  const original = normalizeMemoryText(command);
  if (!original) return null;
  // Explicit opt-in guard: no memory changes unless the message carries @memory.
  const tagMatch = original.match(/^@memory\b\s*[:,]?\s*(.*)$/i);
  if (!tagMatch) return null;
  const text = normalizeMemoryText(tagMatch[1]);
  if (!text) return { operation: "help" };

  if (/^(what do you remember(?: about .+)?|show(?: me)? (?:my )?memories|list (?:my )?memories|open memory garden|show memory garden)$/i.test(text)) {
    const about = text.match(/^what do you remember about (.+)$/i);
    return { operation: "read", query: about ? about[1] : "" };
  }

  let match = text.match(/^(?:please )?(?:remember(?: that)?|save to memory(?: that)?|store in memory(?: that)?)\s+(.+)$/i);
  if (match) return { operation: "add", text: normalizeMemoryText(match[1]) };

  match = text.match(/^(?:please )?(?:forget(?: that)?|remove from memory|delete from memory)\s+(.+)$/i);
  if (match) return { operation: "remove", target: normalizeMemoryText(match[1]) };

  match = text.match(/^(?:please )?(?:change|update) (?:my )?(?:saved )?memory from (.+?) to (.+)$/i);
  if (match) return { operation: "update", target: normalizeMemoryText(match[1]), text: normalizeMemoryText(match[2]) };

  // “Update it to X” refers to the most recently saved/updated memory; no AI call.
  match = text.match(/^(?:please )?(?:change|update|rename) (?:it|that|this) to (.+)$/i);
  if (match) return { operation: "updateRecent", text: normalizeMemoryText(match[1]) };

  match = text.match(/^(?:please )?(?:change|update) (?:my )?(.+?) to (.+)$/i);
  if (match && /\b(my|saved|memory|remembered|project|name|school|goal|preference|timezone|time zone|nickname|device|plan)\b/i.test(match[1])) {
    return { operation: "update", target: normalizeMemoryText(match[1]), text: normalizeMemoryText(match[2]), flexible: true };
  }

  return null;
}

function memoryTargetMatches(memory, target) {
  const haystack = normalizeMemoryText(memory.text).toLowerCase();
  const needle = normalizeMemoryText(target).toLowerCase();
  if (!needle) return false;
  if (haystack.includes(needle) || needle.includes(haystack)) return true;
  const words = memoryWords(needle);
  if (!words.length) return false;
  const memoryText = haystack;
  const overlap = words.filter((word) => memoryText.includes(word)).length;
  // Short key phrases such as “project name” should match a saved sentence
  // such as “my project is called grassOS”; callers still change/remove only one best match.
  return overlap >= (words.length <= 3 ? 1 : Math.ceil(words.length * 0.5));
}

function handleLoadMemories(credential) {
  const auth = authenticateCredential(credential);
  return jsonResponse({
    success: true,
    memories: readAccountMemories(auth.account),
  });
}

function handleMemoryCommand(credential, rawCommand) {
  const auth = authenticateCredential(credential);
  const parsed = parseGrassMemoryCommand(rawCommand);
  if (!parsed) {
    return jsonResponse({ success: true, isMemoryCommand: false });
  }

  const lock = LockService.getScriptLock();
  lock.waitLock(10000);
  try {
    let memories = readAccountMemories(auth.account);
    const now = new Date().toISOString();
    let message = "";

    if (parsed.operation === "help") {
      return jsonResponse({
        success: true,
        isMemoryCommand: true,
        memories,
        message: "🌱 Start with @memory to manage saved information. Examples: @memory remember that my project is called grassOS; @memory update it to grassOS 2; @memory what do you remember about my project?",
      });
    }

    if (parsed.operation === "read") {
      const queryWords = memoryWords(parsed.query || "");
      const shown = queryWords.length
        ? memories.filter((memory) => queryWords.some((word) => memory.text.toLowerCase().includes(word)))
        : memories;
      message = shown.length
        ? "🌱 Here's what is in your Memory Garden:\n\n" + shown.map((memory) => "• " + memory.text).join("\n")
        : (memories.length ? "🌱 I couldn't find a saved memory matching that topic." : "🌱 Your Memory Garden is empty for now. Tell me **'Remember that ...'** to plant your first memory.");
      return jsonResponse({ success: true, isMemoryCommand: true, operation: "read", memories: memories, message: message });
    }

    if (parsed.operation === "add") {
      const value = normalizeMemoryText(parsed.text);
      if (!value) throw new Error("Tell me what you'd like me to remember.");
      if (value.length > GRASS_MEMORY_MAX_TEXT_LENGTH) throw new Error("Memories must be 500 characters or fewer.");
      const duplicate = memories.find((memory) => normalizeMemoryText(memory.text).toLowerCase() === value.toLowerCase());
      if (duplicate) {
        message = "🌱 I already have that saved in your Memory Garden.";
      } else {
        if (memories.length >= GRASS_MEMORY_MAX_ITEMS) throw new Error("Your Memory Garden is full. Forget a memory before adding another.");
        memories.unshift({ id: Utilities.getUuid(), text: value, createdAt: now, updatedAt: now });
        writeAccountMemories(auth.account, memories);
        message = "🌱 Memory planted! I'll keep it in your Memory Garden. (This operation used zero AI model tokens.)";
      }
    } else if (parsed.operation === "update" || parsed.operation === "updateRecent") {
      let index;
      if (parsed.operation === "updateRecent") {
        // Resolve pronouns deterministically to the newest memory.
        index = memories.reduce((best, memory, current) => {
          if (best < 0) return current;
          const a = Date.parse(memories[best].updatedAt || memories[best].createdAt || "") || 0;
          const b = Date.parse(memory.updatedAt || memory.createdAt || "") || 0;
          return b > a ? current : best;
        }, -1);
      } else {
        index = memories.findIndex((memory) => memoryTargetMatches(memory, parsed.target));
      }
      if (index < 0) {
        // A vague “change my … to …” is ordinary chat unless it matches a saved memory.
        if (parsed.flexible) return jsonResponse({ success: true, isMemoryCommand: false });
        message = "🌱 I couldn't find a saved memory matching that description. Nothing was changed.";
      } else {
        const value = normalizeMemoryText(parsed.text);
        if (!value) throw new Error("Tell me what the updated memory should say.");
        if (value.length > GRASS_MEMORY_MAX_TEXT_LENGTH) throw new Error("Memories must be 500 characters or fewer.");
        let updatedText;
        if (parsed.operation === "updateRecent") {
          const previous = normalizeMemoryText(memories[index].text);
          // Preserve the subject for common fact patterns like “my project is called grassOS”.
          if (/\b(?:is called|is named|called|named)\b/i.test(previous)) {
            updatedText = previous.replace(/(\b(?:is called|is named|called|named)\s+).+$/i, "$1" + value);
          } else if (/\b(?:project|school|goal|device|nickname|plan|name)\b/i.test(previous) && /\b(?:is|are)\b/i.test(previous)) {
            updatedText = previous.replace(/(\b(?:is|are)\s+).+$/i, "$1" + value);
          } else {
            updatedText = value;
          }
        } else {
          updatedText = parsed.flexible
            ? "My " + normalizeMemoryText(parsed.target).replace(/^my\s+/i, "") + " is " + value
            : value;
        }
        if (updatedText.length > GRASS_MEMORY_MAX_TEXT_LENGTH) throw new Error("Memories must be 500 characters or fewer.");
        memories[index] = { ...memories[index], text: updatedText, updatedAt: now };
        writeAccountMemories(auth.account, memories);
        message = "🌱 Memory updated! Your Memory Garden is up to date.";
      }
    } else if (parsed.operation === "remove") {
      const matchIndex = memories.findIndex((memory) => memoryTargetMatches(memory, parsed.target));
      if (matchIndex < 0) {
        message = "🌱 I couldn't find a saved memory matching that description, so nothing was removed.";
      } else {
        memories.splice(matchIndex, 1);
        writeAccountMemories(auth.account, memories);
        message = "🌱 Memory removed from your Memory Garden.";
      }
    }

    return jsonResponse({ success: true, isMemoryCommand: true, operation: parsed.operation, memories: memories, message: message });
  } finally {
    lock.releaseLock();
  }
}

/* =========================
   ACCOUNT STORAGE HELPERS
   ========================= */

function getStorageAccountKey(
  account
) {
  /*
   * Email accounts:
   *
   * STORAGE_PREFIX +
   * SHA256("email:" + normalized email)
   */
  if (
    account.provider ===
    "email"
  ) {
    return getEmailAccountKey(
      account.email
    );
  }

  /*
   * Existing Google accounts:
   *
   * Their account ID is already
   * SHA-256(Google sub), so use it
   * directly to preserve all existing
   * conversation storage.
   */
  return (
    STORAGE_PREFIX +
    account.id
  );
}

/* =========================
   RAW STORAGE
   ========================= */

function loadRawStorage(
  accountKey
) {
  const properties =
    getProperties();

  const metaRaw =
    properties.getProperty(
      getMetaKey(accountKey)
    );

  if (!metaRaw) {
    return null;
  }

  let meta;

  try {
    meta =
      JSON.parse(
        metaRaw
      );
  } catch (error) {
    throw new Error(
      "grassAI storage metadata is corrupted."
    );
  }

  const chunkCount =
    Number(
      meta.chunkCount || 0
    );

  if (
    !Number.isInteger(
      chunkCount
    ) ||
    chunkCount < 0
  ) {
    throw new Error(
      "grassAI storage metadata is invalid."
    );
  }

  if (chunkCount === 0) {
    return "";
  }

  let combined = "";

  for (
    let index = 0;
    index < chunkCount;
    index++
  ) {
    const chunk =
      properties.getProperty(
        getChunkKey(
          accountKey,
          index
        )
      );

    if (chunk === null) {
      throw new Error(
        "A saved grassAI chat segment is missing."
      );
    }

    combined += chunk;
  }

  return combined;
}

function saveRawStorage(
  accountKey,
  serialized
) {
  const properties =
    getProperties();

  const chunkCount =
    Math.ceil(
      serialized.length /
        CHAT_CHUNK_SIZE
    );

  const oldMetaRaw =
    properties.getProperty(
      getMetaKey(accountKey)
    );

  let oldChunkCount = 0;

  if (oldMetaRaw) {
    try {
      const oldMeta =
        JSON.parse(
          oldMetaRaw
        );

      oldChunkCount =
        Number(
          oldMeta.chunkCount ||
            0
        );
    } catch (error) {
      oldChunkCount = 0;
    }
  }

  const totalChunks =
    Math.max(
      oldChunkCount,
      chunkCount
    );

  for (
    let index = 0;
    index < totalChunks;
    index++
  ) {
    properties.deleteProperty(
      getChunkKey(
        accountKey,
        index
      )
    );
  }

  for (
    let index = 0;
    index < chunkCount;
    index++
  ) {
    const start =
      index *
      CHAT_CHUNK_SIZE;

    const end =
      start +
      CHAT_CHUNK_SIZE;

    properties.setProperty(
      getChunkKey(
        accountKey,
        index
      ),
      serialized.slice(
        start,
        end
      )
    );
  }

  properties.setProperty(
    getMetaKey(accountKey),
    JSON.stringify({
      version: 2,

      chunkCount:
        chunkCount,

      updatedAt:
        new Date().toISOString(),
    })
  );
}

/* =========================
   MESSAGE CLEANING
   ========================= */

function cleanMessages(
  messages
) {
  if (
    !Array.isArray(messages)
  ) {
    return [];
  }

  return messages
    .filter(
      function (message) {
        return (
          message &&
          typeof message.text ===
            "string" &&
          (
            message.sender ===
              "user" ||
            message.sender ===
              "assistant"
          )
        );
      }
    )
    .map(
      function (message) {
        const cleaned = {
          id:
            message.id ||
            Date.now(),

          text:
            message.text,

          sender:
            message.sender,
        };

        if (
          message.image &&
          typeof message.image ===
            "object"
        ) {
          cleaned.image = {
            name:
              typeof message.image.name ===
              "string"
                ? message.image.name
                : "",

            type:
              typeof message.image.type ===
              "string"
                ? message.image.type
                : "",
          };
        }

        return cleaned;
      }
    );
}

/* =========================
   CONVERSATION CLEANING
   ========================= */

function cleanConversations(
  conversations
) {
  if (
    !Array.isArray(
      conversations
    )
  ) {
    return [];
  }

  return conversations
    .filter(
      function (conversation) {
        return (
          conversation &&
          typeof conversation.id ===
            "string"
        );
      }
    )
    .map(
      function (conversation) {
        return {
          id:
            conversation.id,

          title:
            typeof conversation.title ===
            "string"
              ? conversation.title
              : "New chat",

          messages:
            cleanMessages(
              conversation.messages
            ),

          createdAt:
            conversation.createdAt ||
            new Date().toISOString(),

          updatedAt:
            conversation.updatedAt ||
            new Date().toISOString(),
        };
      }
    );
}

/* =========================
   STORAGE MIGRATION
   ========================= */

function loadConversations(
  accountKey
) {
  const raw =
    loadRawStorage(
      accountKey
    );

  if (!raw) {
    return [];
  }

  let parsed;

  try {
    parsed =
      JSON.parse(raw);
  } catch (error) {
    throw new Error(
      "The saved grassAI data could not be decoded."
    );
  }

  /*
   * Old format:
   * [
   *   { sender, text, ... }
   * ]
   */
  if (
    Array.isArray(parsed)
  ) {
    const oldMessages =
      cleanMessages(
        parsed
      );

    if (
      oldMessages.length === 0
    ) {
      return [];
    }

    return [
      {
        id:
          "conversation-" +
          Date.now(),

        title:
          createConversationTitle(
            oldMessages
          ),

        messages:
          oldMessages,

        createdAt:
          new Date().toISOString(),

        updatedAt:
          new Date().toISOString(),
      },
    ];
  }

  /*
   * Current format:
   * {
   *   version: 2,
   *   conversations: [...]
   * }
   */
  if (
    parsed &&
    Array.isArray(
      parsed.conversations
    )
  ) {
    return cleanConversations(
      parsed.conversations
    );
  }

  return [];
}

function saveConversations(
  accountKey,
  conversations
) {
  const cleaned =
    cleanConversations(
      conversations
    );

  const payload =
    JSON.stringify({
      version: 2,

      conversations:
        cleaned,
    });

  saveRawStorage(
    accountKey,
    payload
  );

  return cleaned;
}

/* =========================
   TITLES
   ========================= */

function createConversationTitle(
  messages
) {
  if (
    !Array.isArray(messages)
  ) {
    return "New chat";
  }

  const firstUserMessage =
    messages.find(
      function (message) {
        return (
          message.sender ===
          "user"
        );
      }
    );

  if (
    !firstUserMessage ||
    !firstUserMessage.text
  ) {
    return "New chat";
  }

  let title =
    firstUserMessage.text
      .replace(/\s+/g, " ")
      .trim();

  if (
    title.length > 34
  ) {
    title =
      title
        .slice(0, 34)
        .trim() +
      "…";
  }

  return (
    title ||
    "New chat"
  );
}

/* =========================
   PER-CONVERSATION USAGE
   ========================= */

function getChatUsagePropertyKey(account, conversationId) {
  if (!conversationId || typeof conversationId !== "string") {
    throw new Error("A conversation ID is required.");
  }
  const accountKey = getStorageAccountKey(account);
  return "grassAI_usage_" + sha256Hex(accountKey + "|" + conversationId);
}

function readChatUsage(account, conversationId) {
  const raw = getProperties().getProperty(
    getChatUsagePropertyKey(account, conversationId)
  );
  const count = Number(raw || 0);
  return Number.isFinite(count) && count > 0 ? Math.floor(count) : 0;
}

function writeChatUsage(account, conversationId, count) {
  getProperties().setProperty(
    getChatUsagePropertyKey(account, conversationId),
    String(Math.max(0, Math.floor(Number(count) || 0)) )
  );
}

function handleGetChatUsage(credential, conversationId) {
  const auth = authenticateCredential(credential);
  const usageCount = readChatUsage(auth.account, conversationId);
  return jsonResponse({
    success: true,
    conversationId: conversationId,
    usageCount: usageCount,
    usageLimit: GRASS_CHAT_MESSAGE_LIMIT,
    exhausted: usageCount >= GRASS_CHAT_MESSAGE_LIMIT
  });
}

/* =========================
   LOAD CONVERSATIONS
   ========================= */

function handleLoadConversations(
  credential
) {
  const auth =
    authenticateCredential(
      credential
    );

  const accountKey =
    getStorageAccountKey(
      auth.account
    );

  const lock =
    LockService.getScriptLock();

  lock.waitLock(10000);

  try {
    const raw =
      loadRawStorage(
        accountKey
      );

    const conversations =
      loadConversations(
        accountKey
      );

    /*
     * Convert old array-format storage
     * into the current conversation format.
     */
    if (raw) {
      try {
        const parsed =
          JSON.parse(raw);

        if (
          Array.isArray(parsed)
        ) {
          saveConversations(
            accountKey,
            conversations
          );
        }
      } catch (error) {
        /*
         * Keep existing handling.
         */
      }
    }

    const conversationsWithUsage = conversations.map(function (conversation) {
      return Object.assign({}, conversation, {
        usageCount: readChatUsage(auth.account, conversation.id),
        usageLimit: GRASS_CHAT_MESSAGE_LIMIT
      });
    });

    return jsonResponse({
      success: true,
      conversations: conversationsWithUsage,
    });
  } finally {
    lock.releaseLock();
  }
}

/* =========================
   SAVE CONVERSATIONS
   ========================= */

function handleSaveConversations(
  credential,
  conversationsJson
) {
  const auth =
    authenticateCredential(
      credential
    );

  const accountKey =
    getStorageAccountKey(
      auth.account
    );

  let incoming;

  try {
    incoming =
      JSON.parse(
        conversationsJson ||
          "[]"
      );
  } catch (error) {
    throw new Error(
      "Invalid conversation data."
    );
  }

  incoming =
    cleanConversations(
      incoming
    );

  const lock =
    LockService.getScriptLock();

  lock.waitLock(10000);

  try {
    const saved =
      saveConversations(
        accountKey,
        incoming
      );

    return jsonResponse({
      success: true,

      conversations:
        saved,
    });
  } finally {
    lock.releaseLock();
  }
}

/* =========================
   OLD LOAD CHAT COMPATIBILITY
   ========================= */

function handleLoadChat(
  credential
) {
  const auth =
    authenticateCredential(
      credential
    );

  const accountKey =
    getStorageAccountKey(
      auth.account
    );

  const conversations =
    loadConversations(
      accountKey
    );

  if (
    conversations.length === 0
  ) {
    return jsonResponse({
      success: true,

      messages: [],
    });
  }

  return jsonResponse({
    success: true,

    messages:
      conversations[0]
        .messages,
  });
}

/* =========================
   OLD SAVE CHAT COMPATIBILITY
   ========================= */

function handleSaveChat(
  credential,
  messagesJson
) {
  const auth =
    authenticateCredential(
      credential
    );

  const accountKey =
    getStorageAccountKey(
      auth.account
    );

  let incoming;

  try {
    incoming =
      JSON.parse(
        messagesJson || "[]"
      );
  } catch (error) {
    throw new Error(
      "Invalid chat data."
    );
  }

  incoming =
    cleanMessages(
      incoming
    );

  const lock =
    LockService.getScriptLock();

  lock.waitLock(10000);

  try {
    let conversations =
      loadConversations(
        accountKey
      );

    if (
      conversations.length === 0
    ) {
      conversations = [
        {
          id:
            "conversation-" +
            Date.now(),

          title:
            createConversationTitle(
              incoming
            ),

          messages:
            incoming,

          createdAt:
            new Date().toISOString(),

          updatedAt:
            new Date().toISOString(),
        },
      ];
    } else {
      conversations[0].messages =
        incoming;

      conversations[0].updatedAt =
        new Date().toISOString();

      if (
        conversations[0].title ===
        "New chat"
      ) {
        conversations[0].title =
          createConversationTitle(
            incoming
          );
      }
    }

    saveConversations(
      accountKey,
      conversations
    );

    return jsonResponse({
      success: true,

      messages:
        conversations[0]
          .messages,
    });
  } finally {
    lock.releaseLock();
  }
}

/* =========================
   OLD MIGRATION
   ========================= */

function handleMigrateChat(
  credential,
  messagesJson
) {
  const auth =
    authenticateCredential(
      credential
    );

  const accountKey =
    getStorageAccountKey(
      auth.account
    );

  let incoming;

  try {
    incoming =
      JSON.parse(
        messagesJson || "[]"
      );
  } catch (error) {
    throw new Error(
      "Invalid migration data."
    );
  }

  incoming =
    cleanMessages(
      incoming
    );

  if (
    incoming.length === 0
  ) {
    return jsonResponse({
      success: true,

      migrated: false,

      messages: [],
    });
  }

  const lock =
    LockService.getScriptLock();

  lock.waitLock(10000);

  try {
    let conversations =
      loadConversations(
        accountKey
      );

    if (
      conversations.length === 0
    ) {
      conversations = [
        {
          id:
            "conversation-" +
            Date.now(),

          title:
            createConversationTitle(
              incoming
            ),

          messages:
            incoming,

          createdAt:
            new Date().toISOString(),

          updatedAt:
            new Date().toISOString(),
        },
      ];
    } else {
      conversations[0].messages =
        mergeMessages(
          conversations[0]
            .messages,
          incoming
        );

      conversations[0].updatedAt =
        new Date().toISOString();
    }

    saveConversations(
      accountKey,
      conversations
    );

    return jsonResponse({
      success: true,

      migrated: true,

      messages:
        conversations[0]
          .messages,
    });
  } finally {
    lock.releaseLock();
  }
}

/* =========================
   MESSAGE MERGING
   ========================= */

function mergeMessages(
  existing,
  incoming
) {
  const combined = [
    ...(Array.isArray(existing)
      ? existing
      : []),

    ...(Array.isArray(incoming)
      ? incoming
      : []),
  ];

  const byId = {};

  combined.forEach(
    function (message) {
      if (
        message &&
        message.id !==
          undefined
      ) {
        byId[
          String(message.id)
        ] = message;
      }
    }
  );

  return Object.keys(byId)
    .map(
      function (key) {
        return byId[key];
      }
    )
    .sort(
      function (a, b) {
        const aId =
          Number(a.id);

        const bId =
          Number(b.id);

        if (
          Number.isNaN(aId) ||
          Number.isNaN(bId)
        ) {
          return String(
            a.id
          ).localeCompare(
            String(b.id)
          );
        }

        return (
          aId - bId
        );
      }
    );
}

/* =========================
   MODEL VALIDATION
   ========================= */

function normalizeModel(
  model
) {
  if (
    model &&
    GRASSAI_MODELS[model]
  ) {
    return model;
  }

  return DEFAULT_MODEL;
}

/* =========================
   IMAGE VALIDATION
   ========================= */

function parseImages(
  imagesJson
) {
  if (!imagesJson) {
    return [];
  }

  let images;

  try {
    images =
      JSON.parse(
        imagesJson
      );
  } catch (error) {
    throw new Error(
      "The attached image data could not be decoded."
    );
  }

  if (
    !Array.isArray(images)
  ) {
    throw new Error(
      "Invalid image attachment data."
    );
  }

  if (
    images.length >
    MAX_IMAGES
  ) {
    throw new Error(
      "You can attach up to " +
        MAX_IMAGES +
        " images per message."
    );
  }

  const cleaned =
    images.map(
      function (image) {
        if (
          !image ||
          typeof image.dataUrl !==
            "string"
        ) {
          throw new Error(
            "One of the attached images is invalid."
          );
        }

        const dataUrl =
          image.dataUrl;

        if (
          dataUrl.length >
          MAX_IMAGE_DATA_LENGTH
        ) {
          throw new Error(
            "One of the attached images is too large."
          );
        }

        if (
          !dataUrl.startsWith(
            "data:image/"
          )
        ) {
          throw new Error(
            "Only image attachments are supported."
          );
        }

        return {
          name:
            typeof image.name ===
            "string"
              ? image.name
              : "image",

          type:
            typeof image.type ===
            "string"
              ? image.type
              : "",

          dataUrl:
            dataUrl,
        };
      }
    );

  return cleaned;
}

/* =========================
   GRASS INTELLIGENCE ENGINE
   ========================= */

function grassEstimateTokens(value) {
  return Math.ceil(
    String(value || "").length /
      GRASS_CHARS_PER_ESTIMATED_TOKEN
  );
}

function grassNormalizeText(value) {
  return String(value || "")
    .toLowerCase()
    .replace(/https?:\/\/\S+/g, " ")
    .replace(/[^a-z0-9_+#.-]+/g, " ")
    .trim();
}

function grassGetKeywords(value) {
  const stopWords = {
    the: 1, and: 1, for: 1, that: 1, this: 1, with: 1,
    from: 1, have: 1, what: 1, when: 1, where: 1, which: 1,
    would: 1, could: 1, should: 1, about: 1, please: 1,
    help: 1, explain: 1, tell: 1, give: 1, make: 1, into: 1,
    your: 1, you: 1, are: 1, was: 1, were: 1, can: 1,
    how: 1, why: 1, who: 1, its: 1, it: 1, them: 1,
    then: 1, than: 1, not: 1, but: 1, all: 1, just: 1,
    like: 1, also: 1, really: 1, please: 1
  };
  const words = grassNormalizeText(value).split(/\s+/);
  const result = {};
  words.forEach(function (word) {
    if (word.length >= 3 && !stopWords[word]) {
      result[word] = (result[word] || 0) + 1;
    }
  });
  return result;
}

function grassAnalyzePrompt(userMessage, history, hasImages) {
  const text = String(userMessage || "").trim();
  const normalized = grassNormalizeText(text);
  const hasFollowUpReference = /\b(it|that|those|them|they|this|these|same|previous|earlier|above|continue|again|instead|what about|and then|the other one)\b/i.test(text);
  const isCoding = /\b(code|coding|program|programming|debug|bug|error|javascript|python|html|css|react|api|function|script|backend|frontend|compile|syntax)\b/i.test(text);
  const isDetailed = /\b(step by step|in detail|detailed|comprehensive|deep dive|full explanation|show working|derive|prove|analyse|analyze|compare|evaluate)\b/i.test(text);
  const isShortAnswer = /\b(just the answer|short answer|briefly|in one sentence|no explanation)\b/i.test(text);
  const isSchoolwork = /\b(homework|worksheet|exam|examination|sec [1-5]|biology|chemistry|physics|mathematics|maths|geography|history|literature|school|question [0-9])\b/i.test(text);
  let task = "general";
  if (hasImages) task = "image-analysis";
  else if (isCoding) task = "coding";
  else if (isSchoolwork) task = "learning";
  else if (isDetailed) task = "detailed-explanation";
  else if (isShortAnswer) task = "concise-answer";

  // Keep the user's exact text. GRASS classifies and routes; it does not
  // silently rewrite the request or call another model to paraphrase it.
  return {
    task: task,
    normalized: normalized,
    keywords: grassGetKeywords(text),
    needsHistory: hasFollowUpReference || /\b(you said|we discussed|remember when|my project|my previous|as i said|as mentioned)\b/i.test(text),
    hasImages: !!hasImages,
    isDetailed: isDetailed,
    isShortAnswer: isShortAnswer,
    historyLength: Array.isArray(history) ? history.length : 0
  };
}

function grassHistoryRelevance(message, keywords, index, historyLength) {
  const messageKeywords = grassGetKeywords(message && message.text);
  let score = 0;
  Object.keys(keywords).forEach(function (word) {
    if (messageKeywords[word]) score += Math.min(keywords[word], 2) * (word.length >= 7 ? 2 : 1);
  });
  // Recency matters, but does not override a strong topical match.
  score += Math.max(0, 1 - ((historyLength - 1 - index) / Math.max(historyLength, 1))) * 1.5;
  if (message && message.sender === "user") score += 0.15;
  return score;
}

function grassSelectHistory(history, analysis, systemPrompt, userMessage, hasImages) {
  if (!Array.isArray(history) || history.length === 0) {
    return { messages: [], estimatedInputTokens: grassEstimateTokens(systemPrompt) + grassEstimateTokens(userMessage) };
  }

  const budget = hasImages ? GRASS_IMAGE_INPUT_BUDGET : GRASS_TEXT_INPUT_BUDGET;
  // Keep margin for role wrappers, image metadata, and differences between
  // character-based estimates and the provider's tokenizer.
  const safetyMargin = hasImages ? 180 : 220;
  const fixedTokens = grassEstimateTokens(systemPrompt) + grassEstimateTokens(userMessage) + safetyMargin;
  let remaining = Math.max(0, budget - fixedTokens);
  if (remaining <= 0) {
    throw new Error("Your message is too large to process safely. Please shorten it and try again.");
  }

  const valid = history.map(function (message, index) {
    return { message: message, index: index };
  }).filter(function (item) {
    const m = item.message;
    return m && typeof m.text === "string" && m.text.trim() &&
      (m.sender === "user" || m.sender === "assistant");
  });

  const chosen = {};
  const recentStart = Math.max(0, valid.length - GRASS_RECENT_MESSAGE_COUNT);
  // Recent context is the default backbone of conversation continuity.
  for (let i = recentStart; i < valid.length; i++) {
    const item = valid[i];
    const cost = grassEstimateTokens(item.message.text) + 8;
    if (cost <= remaining) {
      chosen[item.index] = { item: item, cost: cost, priority: 100 + i };
      remaining -= cost;
    }
  }

  // Only spend budget on older history when it is relevant to the current
  // request or the request explicitly refers to earlier conversation.
  if (analysis.needsHistory && remaining > 0) {
    const older = valid.slice(0, recentStart).map(function (item) {
      return {
        item: item,
        cost: grassEstimateTokens(item.message.text) + 8,
        score: grassHistoryRelevance(item.message, analysis.keywords, item.index, history.length)
      };
    }).filter(function (entry) {
      return entry.score >= 1.25;
    }).sort(function (a, b) {
      return b.score - a.score || b.item.index - a.item.index;
    }).slice(0, GRASS_MAX_RELEVANT_OLDER_MESSAGES);

    older.forEach(function (entry) {
      if (entry.cost <= remaining) {
        chosen[entry.item.index] = { item: entry.item, cost: entry.cost, priority: entry.score };
        remaining -= entry.cost;
      }
    });
  }

  const selected = Object.keys(chosen).map(function (key) {
    return chosen[key].item;
  }).sort(function (a, b) {
    return a.index - b.index;
  }).map(function (entry) {
    return entry.message;
  });

  // Avoid beginning with an assistant answer whose question was omitted.
  while (selected.length && selected[0].sender === "assistant") selected.shift();

  return {
    messages: selected,
    estimatedInputTokens: budget - remaining,
    task: analysis.task
  };
}

function grassBuildTaskGuidance(analysis) {
  const guidance = {
    general: "Answer the user's actual request directly. Use prior context only when it helps.",
    "image-analysis": "Inspect the supplied image carefully and ground observations in visible details. Do not invent unreadable details.",
    coding: "For coding requests, preserve stated requirements and explain important changes. Do not remove unrelated existing features.",
    learning: "For learning requests, explain clearly at the appropriate level and show working when useful.",
    "detailed-explanation": "The user appears to want depth; organize the explanation and include important reasoning.",
    "concise-answer": "Keep the answer brief and focused, respecting the user's request for concision."
  };
  return guidance[analysis.task] || guidance.general;
}

/* =========================
   AI CHAT
   ========================= */

function handleChat(
  userMessage,
  historyJson,
  credential,
  requestedModel,
  imagesJson,
  conversationId
) {
  const auth = authenticateCredential(credential);
  return handleChatForAccount(
    userMessage,
    historyJson,
    auth.account,
    requestedModel,
    imagesJson,
    conversationId
  );
}

// grassNotch does not ask users to sign in. A per-install UUID scopes its
// conversation usage; it is not an authentication credential. The endpoint is
// public, so a hard server-side daily ceiling limits provider spend even if
// callers rotate or spoof install IDs.
function handleGrassNotchChat(userMessage, historyJson, clientId, conversationId, imagesJson) {
  if (typeof clientId !== "string" || !/^[0-9a-f-]{36}$/i.test(clientId)) {
    throw new Error("The grassNotch installation ID is invalid. Restart grassNotch and try again.");
  }
  if (typeof conversationId !== "string" || !/^[0-9a-f-]{36}$/i.test(conversationId)) {
    throw new Error("The grassNotch conversation ID is invalid. Start a new conversation and try again.");
  }
  if (typeof userMessage !== "string" || !userMessage.trim() || userMessage.length > 10000) {
    throw new Error("Enter a message under 10,000 characters.");
  }
  if (historyJson && (typeof historyJson !== "string" || historyJson.length > 80000)) {
    throw new Error("This conversation is too long to send. Start a new conversation and try again.");
  }
  if (imagesJson && (typeof imagesJson !== "string" || imagesJson.length > GRASSNOTCH_MAX_IMAGE_DATA_LENGTH)) {
    throw new Error("The shared screen image is too large. Try again with a smaller screen or window.");
  }

  reserveGrassNotchDailyRequest(Boolean(imagesJson));

  const guestAccount = {
    id: "notch-" + sha256Hex(clientId),
    provider: "grassNotch",
    // The dedicated grassNotch route deliberately selects grass2 for every
    // native request. Its usage is bounded by the public route's daily caps.
    subscription: "grassNotch",
    email: "",
    name: "grassNotch"
  };
  return handleChatForAccount(
    userMessage,
    historyJson || "[]",
    guestAccount,
    GRASSNOTCH_MODEL,
    imagesJson || "",
    conversationId
  );
}

// Apps Script's public web app has no trustworthy client IP or installation
// identity. This global UTC-day cap is therefore the authoritative cost guard.
function reserveGrassNotchDailyRequest(includesVision) {
  const lock = LockService.getScriptLock();
  lock.waitLock(10000);
  try {
    const properties = getProperties();
    const today = new Date().toISOString().slice(0, 10);
    const dateKey = "grassNotch_daily_date";
    const countKey = "grassNotch_daily_count";
    const visionCountKey = "grassNotch_daily_vision_count";
    const storedDate = properties.getProperty(dateKey);
    const count = storedDate === today
      ? Number(properties.getProperty(countKey) || 0)
      : 0;
    const visionCount = storedDate === today
      ? Number(properties.getProperty(visionCountKey) || 0)
      : 0;

    if (!Number.isFinite(count) || count >= GRASSNOTCH_DAILY_REQUEST_LIMIT) {
      throw new Error("grassNotch has reached its shared daily AI limit. Please try again tomorrow.");
    }
    if (includesVision && (!Number.isFinite(visionCount) || visionCount >= GRASSNOTCH_DAILY_VISION_REQUEST_LIMIT)) {
      throw new Error("grassNotch has reached its shared daily screen-analysis limit. Please try again tomorrow.");
    }
    properties.setProperty(dateKey, today);
    properties.setProperty(countKey, String(count + 1));
    if (storedDate !== today) {
      properties.setProperty(visionCountKey, String(includesVision ? 1 : 0));
    } else if (includesVision) {
      properties.setProperty(visionCountKey, String(visionCount + 1));
    }
  } finally {
    lock.releaseLock();
  }
}

function handleChatForAccount(
  userMessage,
  historyJson,
  account,
  requestedModel,
  imagesJson,
  conversationId
) {
  const model =
    normalizeModel(
      requestedModel
    );

  const modelConfig =
    GRASSAI_MODELS[model];

  if (!conversationId || typeof conversationId !== "string") {
    throw new Error("A conversation ID is required.");
  }

  const usageLock = LockService.getScriptLock();
  usageLock.waitLock(10000);
  try {
    const currentUsage = readChatUsage(account, conversationId);
    if (currentUsage >= GRASS_CHAT_MESSAGE_LIMIT) {
      throw new Error("CHAT_USAGE_LIMIT_REACHED: Usage for this text chat is over. Upgrade or start a new chat for more messages");
    }
  } finally {
    usageLock.releaseLock();
  }

  if (
    modelConfig.premium &&
    account.subscription !== "premium" &&
    account.provider !== "grassNotch"
  ) {
    throw new Error(
      "Premium subscription required for grass2."
    );
  }

  const images =
    parseImages(
      imagesJson
    );

  if (
    images.length > 0 &&
    !modelConfig.visionAllowed
  ) {
    throw new Error(
      "Image analysis is available on grass2 Premium."
    );
  }

  const apiKey =
    PropertiesService
      .getScriptProperties()
      .getProperty(
        "GROQ_API_KEY"
      );

  if (!apiKey) {
    throw new Error(
      "GROQ_API_KEY is not configured."
    );
  }

  if (
    !userMessage ||
    typeof userMessage !==
      "string"
  ) {
    throw new Error(
      "A message is required."
    );
  }

  let history = [];

  if (historyJson) {
    try {
      history =
        JSON.parse(
          historyJson
        );
    } catch (error) {
      history = [];
    }
  }

  let systemPrompt =
    "You are grassAI, a helpful AI assistant. " +
    "Remember and use the conversation history provided to you. " +
    "Give clear, well-structured answers using Markdown when appropriate. " +
    "Use headings, bullet points, numbered lists, bold text, " +
    "and other Markdown formatting when it improves readability. " +
    "For mathematics, use LaTeX notation whenever appropriate. " +
    "Use inline math with \\(...\\) and displayed equations with \\[...\\]. " +
    "Do not use programming-style notation such as (x-2)^3 when presenting mathematical expressions. " +
    "Use proper LaTeX such as \\((x-2)^3\\). " +
    "For fractions, roots, powers, logarithms, equations, and other mathematical notation, prefer LaTeX.";

  if (
    !modelConfig.codingAllowed
  ) {
    systemPrompt +=
      " You are running as grass1, the free non-coding model. " +
      "Do not write, generate, complete, debug, modify, or provide programming code. " +
      "Do not provide code snippets, scripts, source files, SQL, HTML, CSS, JavaScript, " +
      "Python, or other programming-language code. " +
      "If the user asks you to code, explain politely that coding is only available on the grass2 model from the Premium subscription. " +
      "Instead offer a conceptual explanation, algorithm description, or non-code guidance.";
  } else {
    systemPrompt +=
      " You are running as grass2, the Premium coding-capable model. " +
      "You may write, explain, debug, modify, and analyze programming code when requested.";
  }

  if (
    images.length > 0
  ) {
    systemPrompt +=
      " The user has attached one or more images. " +
      "Actually inspect the image content and use it as evidence when answering. " +
      "Do not claim that you cannot see the image. " +
      "If the image contains text, read it carefully. " +
      "If it contains a worksheet, diagram, graph, chart, screenshot, or other visual information, " +
      "analyse the relevant visual details directly.";
  }

  const grassAnalysis = grassAnalyzePrompt(
    userMessage,
    history,
    images.length > 0
  );

  systemPrompt +=
    "\n\nGRASS task guidance: " +
    grassBuildTaskGuidance(grassAnalysis) +
    " Preserve the user's intent and constraints. Do not claim to remember context that was not provided. The user's saved chat remains unchanged; only selected context is sent to the model.";

  const grassPlan = grassSelectHistory(
    history,
    grassAnalysis,
    systemPrompt,
    userMessage,
    images.length > 0
  );

  const groqMessages = [
    {
      role: "system",

      content:
        systemPrompt,
    },
  ];

  grassPlan.messages.forEach(
    function (message) {
      if (message.sender === "user" || message.sender === "assistant") {
        groqMessages.push({
          role: message.sender,
          content: message.text,
        });
      }
    }
  );

  let currentContent = [
    {
      type: "text",

      text:
        userMessage,
    },
  ];

  images.forEach(
    function (image) {
      currentContent.push({
        type:
          "image_url",

        image_url: {
          url:
            image.dataUrl,
        },
      });
    }
  );

  if (
    images.length > 0
  ) {
    groqMessages.push({
      role: "user",

      content:
        currentContent,
    });
  } else {
    groqMessages.push({
      role: "user",

      content:
        userMessage,
    });
  }

  const selectedApiModel =
    images.length > 0
      ? modelConfig.visionModel
      : modelConfig.apiModel;

  const groqResponse =
    UrlFetchApp.fetch(
      "https://api.groq.com/openai/v1/chat/completions",
      {
        method: "post",

        contentType:
          "application/json",

        headers: {
          Authorization:
            "Bearer " +
            apiKey,
        },

        payload:
          JSON.stringify({
            model: selectedApiModel,
            messages: groqMessages,
            max_completion_tokens: images.length > 0
              ? GRASS_IMAGE_OUTPUT_BUDGET
              : GRASS_TEXT_OUTPUT_BUDGET,
          }),

        muteHttpExceptions:
          true,
      }
    );

  const statusCode =
    groqResponse.getResponseCode();

  const responseText =
    groqResponse.getContentText();

  if (
    statusCode < 200 ||
    statusCode >= 300
  ) {
    if (statusCode === 413 || /rate_limit_exceeded|tokens per minute|TPM/i.test(responseText)) {
      throw new Error(
        "GRASS kept your saved conversation intact, but Groq's shared token rate limit was reached. Please wait a little and retry. If it repeats, shorten the current message or start a fresh chat for an unrelated topic."
      );
    }

    throw new Error(
      "Groq API error (" + statusCode + "): " + responseText.slice(0, 1200)
    );
  }

  let groqData;

  try {
    groqData =
      JSON.parse(
        responseText
      );
  } catch (error) {
    throw new Error(
      "Groq returned an invalid response."
    );
  }

  const assistantMessage =
    groqData
      .choices?.[0]
      ?.message?.content;

  if (!assistantMessage) {
    throw new Error(
      "Groq returned no assistant message."
    );
  }

  // Count only requests that returned a usable assistant response.
  const completedUsageLock = LockService.getScriptLock();
  completedUsageLock.waitLock(10000);
  let usageCount;
  try {
    usageCount = readChatUsage(account, conversationId);
    if (usageCount >= GRASS_CHAT_MESSAGE_LIMIT) {
      throw new Error("CHAT_USAGE_LIMIT_REACHED: Usage for this text chat is over. Upgrade or start a new chat for more messages");
    }
    usageCount += 1;
    writeChatUsage(account, conversationId, usageCount);
  } finally {
    completedUsageLock.releaseLock();
  }

  return jsonResponse({
    success: true,

    model:
      model,

    usageCount: usageCount,
    usageLimit: GRASS_CHAT_MESSAGE_LIMIT,
    usageExhausted: usageCount >= GRASS_CHAT_MESSAGE_LIMIT,

    vision:
      images.length > 0,

    grass: {
      task: grassAnalysis.task,
      selectedHistoryMessages: grassPlan.messages.length,
      availableHistoryMessages: Array.isArray(history) ? history.length : 0,
      estimatedInputTokens: grassPlan.estimatedInputTokens,
      outputTokenLimit: images.length > 0 ? GRASS_IMAGE_OUTPUT_BUDGET : GRASS_TEXT_OUTPUT_BUDGET
    },

    message:
      assistantMessage,
  });
}

/* =========================
   ADMIN: GET USERS
   ========================= */

function handleAdminGetUsers(
  credential
) {
  requireAdmin(
    credential
  );

  const properties =
    getProperties();

  const allProperties =
    properties.getProperties();

  const users = [];

  Object.keys(
    allProperties
  ).forEach(
    function (key) {
      if (
        !key.startsWith(
          ACCOUNT_PREFIX
        )
      ) {
        return;
      }

      let account;

      try {
        account =
          JSON.parse(
            allProperties[key]
          );
      } catch (error) {
        return;
      }

      if (
        !account ||
        !account.id ||
        !account.email
      ) {
        return;
      }

      users.push({
        id:
          account.id,

        email:
          account.email,

        name:
          account.name || "",

        picture:
          account.picture || "",

        createdAt:
          account.createdAt || "",

        updatedAt:
          account.updatedAt || "",

        subscription:
          account.subscription ===
          "premium"
            ? "premium"
            : "free",

        provider:
          account.provider ||
          "google",
      });
    }
  );

  users.sort(
    function (a, b) {
      return (
        new Date(
          b.createdAt || 0
        ).getTime() -
        new Date(
          a.createdAt || 0
        ).getTime()
      );
    }
  );

  const premiumCount =
    users.filter(
      function (user) {
        return (
          user.subscription ===
          "premium"
        );
      }
    ).length;

  return jsonResponse({
    success: true,

    users:
      users,

    totalUsers:
      users.length,

    premiumUsers:
      premiumCount,
  });
}

/* =========================
   ADMIN: REVOKE PREMIUM
   ========================= */

function handleAdminRevokePremium(
  credential,
  accountId
) {
  requireAdmin(
    credential
  );

  if (
    !accountId ||
    typeof accountId !==
      "string"
  ) {
    throw new Error(
      "A valid account ID is required."
    );
  }

  const account =
    getAccountRecord(
      accountId
    );

  if (!account) {
    throw new Error(
      "That grassAI account could not be found."
    );
  }

  if (
    normalizeEmail(
      account.email
    ) ===
    ADMIN_EMAIL.toLowerCase()
  ) {
    throw new Error(
      "The administrator account cannot have its own Premium access revoked."
    );
  }

  account.subscription =
    "free";

  account.updatedAt =
    new Date().toISOString();

  saveAccountRecord(
    accountId,
    account
  );

  return jsonResponse({
    success: true,

    message:
      "Premium subscription revoked.",

    user: {
      id:
        account.id,

      email:
        account.email,

      subscription:
        account.subscription,
    },
  });
}
