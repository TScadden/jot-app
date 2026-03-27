package com.notel.notel.ui.screen

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.remote.AuthRequest
import com.notel.notel.data.remote.ForgotPasswordRequest
import com.notel.notel.data.remote.JotApi
import com.notel.notel.data.sync.SyncManager
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import javax.inject.Inject
import com.notel.notel.ui.theme.*
import androidx.compose.ui.graphics.Color
import kotlinx.serialization.json.Json
import kotlinx.serialization.decodeFromString

@HiltViewModel
class LoginViewModel @Inject constructor(
    private val preferences: NotelPreferences,
    private val jotApi: JotApi,
    private val syncManager: SyncManager
) : ViewModel() {
    var isLoggedIn by mutableStateOf<Boolean?>(null)
        private set

    var errorMsg by mutableStateOf<String?>(null)
        private set
        
    var isLoading by mutableStateOf(false)
        private set

    var onboardingCompleteByServer by mutableStateOf<Boolean?>(null)
        private set

    init {
        viewModelScope.launch {
            preferences.loggedIn.collect { status ->
                if (status) {
                    // If already logged in (app restart), fetch the real status from server before proceeding
                    try {
                        syncManager.pullAllData()
                        onboardingCompleteByServer = preferences.onboardingComplete.first()
                    } catch (e: Exception) {
                        // Fallback to local if network fails on app start
                        onboardingCompleteByServer = preferences.onboardingComplete.first()
                    }
                }
                isLoggedIn = status
            }
        }
    }

    var successMsg by mutableStateOf<String?>(null)
        private set

    fun setError(msg: String?) {
        errorMsg = msg
    }

    fun setSuccess(msg: String?) {
        successMsg = msg
    }

    fun forgotPassword(email: String) {
        if (email.isBlank()) {
            errorMsg = "Please enter your email to reset password"
            return
        }

        viewModelScope.launch {
            isLoading = true
            errorMsg = null
            successMsg = null
            
            try {
                val response = jotApi.forgotPassword(ForgotPasswordRequest(email))
                val body = response.body()
                
                if (response.isSuccessful && body?.success == true) {
                    successMsg = body.message ?: "Reset link sent to your email"
                } else {
                    errorMsg = body?.error ?: "Failed to send reset link"
                }
            } catch (e: Exception) {
                errorMsg = e.message ?: "Network error"
            } finally {
                isLoading = false
            }
        }
    }

    fun login(email: String, pass: String) {
        if (email.isBlank() || pass.isBlank()) {
            errorMsg = "Please fill in all fields"
            return
        }
        
        viewModelScope.launch {
            isLoading = true
            errorMsg = null
            
            try {
                val response = jotApi.login(AuthRequest(email, pass))
                val body = response.body()
                
                if (response.isSuccessful && body != null && body.token?.isNotBlank() == true) {
                    // Save JWT token in preferences
                    preferences.setAuthToken(body.token!!)
                    preferences.setLoggedIn(true)
                    
                    // Handle Admin/Friend status and initial balance from server
                    body.isUnlimited?.let { preferences.setIsUnlimited(it) }
                    body.balance?.let { preferences.setUserBalance(it) }
                    syncManager.pullAllData() // Pull existing data on successful login
                    onboardingCompleteByServer = body.onboardingComplete ?: false
                    isLoggedIn = true
                } else {
                    val errorBody = response.errorBody()?.string()
                    val errorMessage = try {
                        if (errorBody != null) {
                            val json = Json { ignoreUnknownKeys = true }
                            json.decodeFromString<com.notel.notel.data.remote.AuthResponse>(errorBody).error
                        } else null
                    } catch (e: Exception) { null }
                    
                    errorMsg = errorMessage ?: (body?.error ?: "Invalid credentials")
                }
            } catch (e: Exception) {
                errorMsg = e.message ?: "Network error"
            } finally {
                isLoading = false
            }
        }
    }

    fun register(email: String, pass: String) {
        if (email.isBlank() || pass.isBlank()) {
            errorMsg = "Please fill in all fields"
            return
        }
        
        viewModelScope.launch {
            isLoading = true
            errorMsg = null
            
            try {
                val response = jotApi.register(AuthRequest(email, pass))
                val body = response.body()
                
                if (response.isSuccessful && body != null && body.token?.isNotBlank() == true) {
                    preferences.setAuthToken(body.token!!)
                    preferences.setLoggedIn(true)
                    preferences.setUserBalance(1.00f) // Start with free $1 credits
                    preferences.setShowFreeCreditPopup(true) // Trigger pop up
                    onboardingCompleteByServer = false // New users always start with onboarding
                    isLoggedIn = true
                } else {
                    val errorStr = response.errorBody()?.string() ?: ""
                    val errorMessage = try {
                        if (errorStr.contains("\"error\":")) {
                           errorStr.substringAfter("\"error\":\"").substringBefore("\"")
                        } else null
                    } catch (e: Exception) { null }
                    
                    errorMsg = errorMessage ?: (body?.error ?: "Registration failed")
                }
            } catch (e: Exception) {
                errorMsg = e.message ?: "Network error"
            } finally {
                isLoading = false
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LoginScreen(
    viewModel: LoginViewModel = hiltViewModel(),
    onLoginSuccess: (Boolean) -> Unit
) {
    var email by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var confirmPassword by remember { mutableStateOf("") }
    var isRegisterMode by remember { mutableStateOf(false) }
    var isForgotPasswordMode by remember { mutableStateOf(false) }
    var passwordVisible by remember { mutableStateOf(false) }
    var confirmPasswordVisible by remember { mutableStateOf(false) }
    
    val loggedIn = viewModel.isLoggedIn
    val errorMsg = viewModel.errorMsg
    val successMsg = viewModel.successMsg
    val isLoading = viewModel.isLoading

    LaunchedEffect(loggedIn, viewModel.onboardingCompleteByServer) {
        if (loggedIn == true && viewModel.onboardingCompleteByServer != null) {
            onLoginSuccess(viewModel.onboardingCompleteByServer!!)
        }
    }

    if (loggedIn == null || (loggedIn == true && viewModel.onboardingCompleteByServer == null)) {
        Box(modifier = Modifier.fillMaxSize().padding(16.dp), contentAlignment = Alignment.Center) {
            GlassySpinner(size = 48.dp)
        }
        return
    }

    Scaffold(
        containerColor = NotelBackground,
        topBar = {
            TopAppBar(
                title = { Text("Welcome to Jot", fontWeight = FontWeight.Black, color = NotelTextPrimary) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = NotelBackground)
            )
        }
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(horizontal = 32.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center
        ) {
            Text(
                text = when {
                    isForgotPasswordMode -> "Reset Password"
                    isRegisterMode -> "Create Account"
                    else -> "Sign In"
                },
                fontSize = 28.sp,
                fontWeight = FontWeight.ExtraBold,
                color = NotelPrimary
            )
            Spacer(modifier = Modifier.height(48.dp))
            
            OutlinedTextField(
                value = email,
                onValueChange = { email = it },
                label = { Text("Email", color = NotelTextSecondary) },
                modifier = Modifier.fillMaxWidth(),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = NotelPrimary,
                    unfocusedBorderColor = NotelTextSecondary,
                    focusedTextColor = NotelTextPrimary,
                    unfocusedTextColor = NotelTextPrimary,
                    cursorColor = NotelPrimary
                ),
                singleLine = true
            )
            
            if (!isForgotPasswordMode) {
                Spacer(modifier = Modifier.height(16.dp))
                
                OutlinedTextField(
                    value = password,
                    onValueChange = { password = it },
                    label = { Text("Password", color = NotelTextSecondary) },
                    modifier = Modifier.fillMaxWidth(),
                    visualTransformation = if (passwordVisible) VisualTransformation.None else PasswordVisualTransformation(),
                    trailingIcon = {
                        val image = if (passwordVisible) Icons.Default.Visibility else Icons.Default.VisibilityOff
                        IconButton(onClick = { passwordVisible = !passwordVisible }) {
                            Icon(imageVector = image, contentDescription = null, tint = NotelTextSecondary)
                        }
                    },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = NotelPrimary,
                        unfocusedBorderColor = NotelTextSecondary,
                        focusedTextColor = NotelTextPrimary,
                        unfocusedTextColor = NotelTextPrimary,
                        cursorColor = NotelPrimary
                    ),
                    singleLine = true
                )
            }
            
            if (isRegisterMode && !isForgotPasswordMode) {
                Spacer(modifier = Modifier.height(16.dp))
                
                OutlinedTextField(
                    value = confirmPassword,
                    onValueChange = { confirmPassword = it },
                    label = { Text("Confirm Password", color = NotelTextSecondary) },
                    modifier = Modifier.fillMaxWidth(),
                    visualTransformation = if (confirmPasswordVisible) VisualTransformation.None else PasswordVisualTransformation(),
                    trailingIcon = {
                        val image = if (confirmPasswordVisible) Icons.Default.Visibility else Icons.Default.VisibilityOff
                        IconButton(onClick = { confirmPasswordVisible = !confirmPasswordVisible }) {
                            Icon(imageVector = image, contentDescription = null, tint = NotelTextSecondary)
                        }
                    },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = NotelPrimary,
                        unfocusedBorderColor = NotelTextSecondary,
                        focusedTextColor = NotelTextPrimary,
                        unfocusedTextColor = NotelTextPrimary,
                        cursorColor = NotelPrimary
                    ),
                    singleLine = true
                )
            }
            
            if (errorMsg != null) {
                Spacer(modifier = Modifier.height(16.dp))
                Text(errorMsg, color = MaterialTheme.colorScheme.error, fontSize = 14.sp)
            }
            if (successMsg != null) {
                Spacer(modifier = Modifier.height(16.dp))
                Text(successMsg, color = Color.Green, fontSize = 14.sp)
            }
            
            Spacer(modifier = Modifier.height(48.dp))
            
            GlassyButton(
                onClick = {
                    viewModel.setError(null)
                    viewModel.setSuccess(null)
                    when {
                        isForgotPasswordMode -> {
                            viewModel.forgotPassword(email)
                        }
                        isRegisterMode -> {
                            if (password != confirmPassword) {
                                viewModel.setError("Passwords do not match")
                            } else {
                                viewModel.register(email, password)
                            }
                        }
                        else -> {
                            viewModel.login(email, password)
                        }
                    }
                },
                modifier = Modifier.fillMaxWidth()
            ) {
                if (isLoading) {
                    CircularProgressIndicator(color = Color.White, modifier = Modifier.size(24.dp))
                } else {
                    Text(
                        text = when {
                            isForgotPasswordMode -> "Send Reset Link"
                            isRegisterMode -> "Register"
                            else -> "Login"
                        },
                        color = Color.White,
                        fontWeight = FontWeight.Bold,
                        fontSize = 18.sp
                    )
                }
            }
            
            Spacer(modifier = Modifier.height(24.dp))
            
            if (!isForgotPasswordMode) {
                TextButton(onClick = { isRegisterMode = !isRegisterMode; viewModel.setError(null); viewModel.setSuccess(null) }) {
                    Text(
                        text = if (isRegisterMode) "Already have an account? Login" else "Don't have an account? Register",
                        color = NotelTextSecondary
                    )
                }
                
                if (!isRegisterMode) {
                    TextButton(onClick = { isForgotPasswordMode = true; viewModel.setError(null); viewModel.setSuccess(null) }) {
                        Text(
                            text = "Forgot Password?",
                            color = NotelPrimary
                        )
                    }
                }
            } else {
                TextButton(onClick = { isForgotPasswordMode = false; viewModel.setError(null); viewModel.setSuccess(null) }) {
                    Text(
                        text = "Back to Login",
                        color = NotelTextSecondary
                    )
                }
            }
        }
    }
}
