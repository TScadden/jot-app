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

    // Hero Slider Logic
    const sliderImages = document.querySelectorAll('.hero-slider .screenshot');
    const dots = document.querySelectorAll('.dot');
    let currentImageIndex = 0;
    let sliderInterval: number | undefined;

    const showImage = (index: number) => {
        // Remove active class from current image and dot
        sliderImages[currentImageIndex].classList.remove('active');
        dots[currentImageIndex].classList.remove('active');
        
        // Update index and add active class to new image and dot
        currentImageIndex = index;
        sliderImages[currentImageIndex].classList.add('active');
        dots[currentImageIndex].classList.add('active');
    };

    const startSlider = () => {
        if (sliderInterval) clearInterval(sliderInterval);
        sliderInterval = window.setInterval(() => {
            const nextIndex = (currentImageIndex + 1) % sliderImages.length;
            showImage(nextIndex);
        }, 4000);
    };

    if (sliderImages.length > 0) {
        startSlider();

        // Add click events to dots
        dots.forEach((dot, index) => {
            dot.addEventListener('click', () => {
                if (currentImageIndex !== index) {
                    showImage(index);
                    startSlider(); // Restart the clock
                }
            });
        });
    }
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
