/* ==========================================================================
   Tabs Authentication Logic & Full-Card Blade Motion Controller
   ========================================================================== */

interface AuthResponse {
    token: string;
    refreshToken?: string;
    userId: string;
    email: string;
    nickname?: string;
    tag?: string;
    onboardingComplete?: boolean;
    error?: string;
}

export const getApiBaseUrl = (): string => {
    const hostname = window.location.hostname;
    if (hostname === 'localhost' || hostname === '127.0.0.1') {
        return 'http://localhost:3000';
    }
    return 'https://api.jottracker.com';
};

export const refreshSessionIfNeeded = async (): Promise<string | null> => {
    const token = localStorage.getItem('token');
    const refreshToken = localStorage.getItem('refreshToken');

    if (!token && !refreshToken) return null;

    try {
        const res = await fetch(`${getApiBaseUrl()}/api/sync/pull`, {
            headers: { 'Authorization': `Bearer ${token}` }
        });

        if (res.ok) return token;

        if (res.status === 401 && refreshToken) {
            const refreshRes = await fetch(`${getApiBaseUrl()}/api/auth/refresh`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ refreshToken })
            });

            if (refreshRes.ok) {
                const data = await refreshRes.json();
                localStorage.setItem('token', data.token);
                if (data.refreshToken) localStorage.setItem('refreshToken', data.refreshToken);
                return data.token;
            }
        }
    } catch (e) {
        return token;
    }

    localStorage.removeItem('token');
    localStorage.removeItem('refreshToken');
    return null;
};

document.addEventListener('DOMContentLoaded', async () => {
    // Session Routing Check
    const activeToken = await refreshSessionIfNeeded();
    if (activeToken) {
        const onboardingComplete = localStorage.getItem('onboardingComplete') === 'true';
        if (!onboardingComplete) {
            window.location.href = '/onboarding.html';
        } else {
            window.location.href = '/dashboard.html';
        }
        return;
    }

    // Main Elements
    const authShell = document.getElementById('main-content') as HTMLElement | null;
    const toggleToRegisterBtn = document.getElementById('toggle-to-register') as HTMLButtonElement | null;
    const toggleToSigninBtn = document.getElementById('toggle-to-signin') as HTMLButtonElement | null;
    const liveAnnouncer = document.getElementById('auth-live-announcer') as HTMLDivElement | null;

    // Content Slots
    const contentSigninLeft = document.getElementById('content-signin-left');
    const contentSignupLeft = document.getElementById('content-signup-left');
    const contentSigninRight = document.getElementById('content-signin-right');
    const contentSignupRight = document.getElementById('content-signup-right');

    // Form elements
    const signinForm = document.getElementById('signin-form') as HTMLFormElement | null;
    const signupForm = document.getElementById('signup-form') as HTMLFormElement | null;

    // Alerts
    const alertSignin = document.getElementById('auth-alert-signin');
    const alertSignup = document.getElementById('auth-alert-signup');

    // Password Toggles
    const toggleSigninPass = document.getElementById('toggle-signin-password') as HTMLButtonElement | null;
    const toggleSignupPass = document.getElementById('toggle-signup-password') as HTMLButtonElement | null;
    const toggleSignupConfirmPass = document.getElementById('toggle-signup-confirm-password') as HTMLButtonElement | null;

    const signinPassInput = document.getElementById('signin-password') as HTMLInputElement | null;
    const signupPassInput = document.getElementById('signup-password') as HTMLInputElement | null;
    const signupConfirmPassInput = document.getElementById('signup-confirm-password') as HTMLInputElement | null;
    const signupEmailInput = document.getElementById('signup-email') as HTMLInputElement | null;

    // Sign Up Validation Checklist
    const reqMinLength = document.getElementById('req-minlength');
    const reqLetterNumber = document.getElementById('req-letternumber');
    const signupEmailError = document.getElementById('signup-email-error');
    const signupConfirmError = document.getElementById('signup-confirm-error');
    const signupTermsError = document.getElementById('signup-terms-error');

    let isAnimating = false;

    // Helper: Show Alert
    const showAlert = (message: string, type: 'error' | 'success', isSignup: boolean) => {
        const targetAlert = isSignup ? alertSignup : alertSignin;
        if (!targetAlert) return;
        targetAlert.textContent = message;
        targetAlert.className = `auth-alert-banner ${type}`;
    };

    const clearAlerts = () => {
        if (alertSignin) alertSignin.style.display = 'none';
        if (alertSignup) alertSignup.style.display = 'none';
    };

    // Password Toggles Setup
    const setupPasswordToggle = (button: HTMLButtonElement | null, input: HTMLInputElement | null) => {
        if (!button || !input) return;
        button.addEventListener('click', () => {
            const isPassword = input.type === 'password';
            input.type = isPassword ? 'text' : 'password';
            button.textContent = isPassword ? 'Hide' : 'Show';
            button.setAttribute('aria-label', isPassword ? 'Hide password' : 'Show password');
        });
    };

    setupPasswordToggle(toggleSigninPass, signinPassInput);
    setupPasswordToggle(toggleSignupPass, signupPassInput);
    setupPasswordToggle(toggleSignupConfirmPass, signupConfirmPassInput);

    // Reduced Motion Detection
    const prefersReducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

    // Full-Card Blade Motion Controller (Cover -> Swap -> Reveal)
    const animateBladeTransition = (toRegister: boolean) => {
        if (isAnimating || !authShell) return;
        isAnimating = true;
        clearAlerts();

        const animClass = toRegister ? 'animating-to-signup' : 'animating-to-signin';
        const targetMode = toRegister ? 'signup' : 'signin';

        if (prefersReducedMotion) {
            // Immediate crossfade for reduced motion mode
            authShell.setAttribute('data-mode', targetMode);
            swapContentSlots(toRegister);
            isAnimating = false;
            announceAndFocus(toRegister);
            return;
        }

        authShell.classList.add('animating', animClass);

        // Midpoint Swap (approx 425ms out of 850ms)
        setTimeout(() => {
            authShell.setAttribute('data-mode', targetMode);
            swapContentSlots(toRegister);
        }, 425);

        // Completion Reveal (850ms)
        setTimeout(() => {
            authShell.classList.remove('animating', 'animating-to-signup', 'animating-to-signin');
            isAnimating = false;
            announceAndFocus(toRegister);
        }, 850);
    };

    const swapContentSlots = (toRegister: boolean) => {
        if (toRegister) {
            contentSigninLeft?.classList.add('hidden');
            contentSignupRight?.classList.remove('hidden');

            contentSigninRight?.classList.add('hidden');
            contentSignupLeft?.classList.remove('hidden');
        } else {
            contentSignupRight?.classList.add('hidden');
            contentSigninLeft?.classList.remove('hidden');

            contentSignupLeft?.classList.add('hidden');
            contentSigninRight?.classList.remove('hidden');
        }
    };

    const announceAndFocus = (toRegister: boolean) => {
        if (toRegister) {
            if (liveAnnouncer) liveAnnouncer.textContent = 'Switched to account creation form.';
            document.getElementById('auth-form-title-signup')?.focus();
        } else {
            if (liveAnnouncer) liveAnnouncer.textContent = 'Switched to sign in form.';
            document.getElementById('auth-form-title-signin')?.focus();
        }
    };

    toggleToRegisterBtn?.addEventListener('click', () => animateBladeTransition(true));
    toggleToSigninBtn?.addEventListener('click', () => animateBladeTransition(false));

    // Live Password Requirements Checking
    if (signupPassInput) {
        signupPassInput.addEventListener('input', () => {
            const val = signupPassInput.value;
            const hasMinLength = val.length >= 8;
            const hasLetterAndNumber = /[a-zA-Z]/.test(val) && /[0-9]/.test(val);

            if (reqMinLength) reqMinLength.classList.toggle('valid', hasMinLength);
            if (reqLetterNumber) reqLetterNumber.classList.toggle('valid', hasLetterAndNumber);

            if (signupConfirmPassInput && signupConfirmPassInput.value.length > 0) {
                const isMatch = val === signupConfirmPassInput.value;
                signupConfirmPassInput.classList.toggle('invalid', !isMatch);
                if (signupConfirmError) {
                    signupConfirmError.classList.toggle('visible', !isMatch);
                    signupConfirmError.textContent = isMatch ? '' : 'Passwords do not match.';
                }
            }
        });
    }

    if (signupConfirmPassInput) {
        signupConfirmPassInput.addEventListener('input', () => {
            const isMatch = signupConfirmPassInput.value === (signupPassInput?.value || '');
            signupConfirmPassInput.classList.toggle('invalid', !isMatch);
            if (signupConfirmError) {
                signupConfirmError.classList.toggle('visible', !isMatch);
                signupConfirmError.textContent = isMatch ? '' : 'Passwords do not match.';
            }
        });
    }

    // Authentication Success Handler
    const handleAuthSuccess = (data: AuthResponse, isNewRegistration: boolean = false) => {
        localStorage.setItem('token', data.token);
        localStorage.setItem('userId', data.userId);
        localStorage.setItem('email', data.email);
        if (data.refreshToken) localStorage.setItem('refreshToken', data.refreshToken);
        if (data.nickname) localStorage.setItem('nickname', data.nickname);
        if (data.tag) localStorage.setItem('tag', data.tag);

        const onboardingComplete = data.onboardingComplete === true;
        localStorage.setItem('onboardingComplete', onboardingComplete ? 'true' : 'false');

        showAlert('Authentication successful! Redirecting...', 'success', isNewRegistration);

        setTimeout(() => {
            if (isNewRegistration || !onboardingComplete) {
                window.location.href = '/onboarding.html';
            } else {
                window.location.href = '/dashboard.html';
            }
        }, 800);
    };

    // Sign In Submission Handler
    signinForm?.addEventListener('submit', async (e: Event) => {
        e.preventDefault();
        clearAlerts();

        const emailInput = document.getElementById('signin-email') as HTMLInputElement;
        const passwordInput = document.getElementById('signin-password') as HTMLInputElement;
        const submitBtn = document.getElementById('signin-submit-btn') as HTMLButtonElement;

        const email = emailInput.value.trim();
        const password = passwordInput.value;

        if (!email || !password) {
            showAlert('Please enter both email address and password.', 'error', false);
            return;
        }

        submitBtn.disabled = true;
        submitBtn.textContent = 'Signing In...';

        try {
            const response = await fetch(`${getApiBaseUrl()}/api/auth/login`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ email, password })
            });

            const data: AuthResponse = await response.json();

            if (response.ok) {
                handleAuthSuccess(data, false);
            } else {
                showAlert(data.error || 'Authentication failed. Please check your credentials.', 'error', false);
                submitBtn.disabled = false;
                submitBtn.textContent = 'Sign In';
            }
        } catch (err) {
            console.error('Sign In error:', err);
            showAlert('Unable to connect to the authentication server.', 'error', false);
            submitBtn.disabled = false;
            submitBtn.textContent = 'Sign In';
        }
    });

    // Create Account Submission Handler
    signupForm?.addEventListener('submit', async (e: Event) => {
        e.preventDefault();
        clearAlerts();

        if (!signupEmailInput || !signupPassInput || !signupConfirmPassInput) return;

        const submitBtn = document.getElementById('signup-submit-btn') as HTMLButtonElement;
        const termsCheckbox = document.getElementById('accept-terms') as HTMLInputElement;

        const email = signupEmailInput.value.trim();
        const password = signupPassInput.value;
        const confirmPassword = signupConfirmPassInput.value;

        let hasError = false;

        signupEmailInput.classList.remove('invalid');
        signupPassInput.classList.remove('invalid');
        signupConfirmPassInput.classList.remove('invalid');
        if (signupEmailError) signupEmailError.classList.remove('visible');
        if (signupConfirmError) signupConfirmError.classList.remove('visible');
        if (signupTermsError) signupTermsError.classList.remove('visible');

        if (!email || !email.includes('@')) {
            signupEmailInput.classList.add('invalid');
            if (signupEmailError) {
                signupEmailError.textContent = 'Please enter a valid email address.';
                signupEmailError.classList.add('visible');
            }
            hasError = true;
        }

        if (password.length < 8) {
            signupPassInput.classList.add('invalid');
            showAlert('Password must be at least 8 characters long.', 'error', true);
            hasError = true;
        }

        if (password !== confirmPassword) {
            signupConfirmPassInput.classList.add('invalid');
            if (signupConfirmError) {
                signupConfirmError.textContent = 'Passwords do not match.';
                signupConfirmError.classList.add('visible');
            }
            hasError = true;
        }

        if (!termsCheckbox.checked) {
            if (signupTermsError) {
                signupTermsError.textContent = 'You must accept the Terms of Service and Privacy Policy.';
                signupTermsError.classList.add('visible');
            }
            hasError = true;
        }

        if (hasError) return;

        submitBtn.disabled = true;
        submitBtn.textContent = 'Creating Account...';

        try {
            const response = await fetch(`${getApiBaseUrl()}/api/auth/register`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ email, password })
            });

            const data: AuthResponse = await response.json();

            if (response.ok) {
                handleAuthSuccess(data, true);
            } else {
                showAlert(data.error || 'Account registration failed. Please try again.', 'error', true);
                submitBtn.disabled = false;
                submitBtn.textContent = 'Create Account';
            }
        } catch (err) {
            console.error('Registration error:', err);
            showAlert('Unable to connect to the server.', 'error', true);
            submitBtn.disabled = false;
            submitBtn.textContent = 'Create Account';
        }
    });
});
