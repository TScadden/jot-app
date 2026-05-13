// Simple intersection observer for reveal animations
const observerOptions = {
    threshold: 0.1
};

const observer = new IntersectionObserver((entries) => {
    entries.forEach(entry => {
        if (entry.isIntersecting) {
            entry.target.classList.add('visible');
            observer.unobserve(entry.target);
        }
    });
}, observerOptions);

document.addEventListener('DOMContentLoaded', () => {
    // Reveal animations
    const revealElements = document.querySelectorAll('.feature-card, .showcase-img, .hero-text, .hero-visual');
    revealElements.forEach(el => {
        el.classList.add('reveal');
        observer.observe(el);
    });

    // Smooth scroll for anchor links
    document.querySelectorAll('a[href^="#"]').forEach(anchor => {
        anchor.addEventListener('click', function (e) {
            e.preventDefault();
            const href = this.getAttribute('href');
            if (href === '#') return;
            
            const target = document.querySelector(href);
            if (target) {
                target.scrollIntoView({
                    behavior: 'smooth'
                });
            }
        });
    });

    // Modal Logic
    const betaModal = document.getElementById('beta-modal');
    const downloadBtns = document.querySelectorAll('.btn-download');
    const closeBtns = document.querySelectorAll('.modal-close, .btn-close-modal');

    downloadBtns.forEach(btn => {
        btn.addEventListener('click', () => {
            betaModal?.classList.add('active');
            document.body.style.overflow = 'hidden'; // Prevent scrolling
        });
    });

    closeBtns.forEach(btn => {
        btn.addEventListener('click', () => {
            betaModal?.classList.remove('active');
            document.body.style.overflow = ''; // Restore scrolling
        });
    });

    // Close modal on background click
    betaModal?.addEventListener('click', (e) => {
        if (e.target === betaModal) {
            betaModal.classList.remove('active');
            document.body.style.overflow = '';
        }
    });

    // Simple parallax effect for hero glow
    window.addEventListener('mousemove', (e) => {
        const glow = document.querySelector('.hero-bg .glow') as HTMLElement;
        if (glow) {
            const x = e.clientX / window.innerWidth;
            const y = e.clientY / window.innerHeight;
            glow.style.transform = `translate(${x * 50}px, ${y * 50}px)`;
        }
    });
});

// Add these styles dynamically for reveal effect
const style = document.createElement('style');
style.textContent = `
    .reveal {
        opacity: 0;
        transform: translateY(30px);
        transition: all 0.8s cubic-bezier(0.4, 0, 0.2, 1);
    }
    .reveal.visible {
        opacity: 1;
        transform: translateY(0);
    }
`;
document.head.appendChild(style);
