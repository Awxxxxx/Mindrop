const root = document.documentElement;
const canvas = document.querySelector("#ambientCanvas");
const ctx = canvas?.getContext("2d");
const reveals = [...document.querySelectorAll(".reveal")];
const counters = [...document.querySelectorAll("[data-count]")];
const demoTabs = [...document.querySelectorAll(".demo-tab")];
const demoScreens = [...document.querySelectorAll(".product-shot")];
const demoCanvas = document.querySelector(".real-demo");
const heroStack = document.querySelector(".screenshot-stack");
const heroCards = [...document.querySelectorAll(".screenshot-stack .shot-card")];
const heroBubble = document.querySelector(".hero-bubble");
const timelineLinks = [...document.querySelectorAll(".timeline-nav a")];
const timelineSections = timelineLinks
  .map(link => document.querySelector(link.getAttribute("href")))
  .filter(Boolean);
const prefersReducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
const isCoarsePointer = window.matchMedia("(pointer: coarse)").matches;
const canUseAmbientCanvas = Boolean(canvas && ctx && !prefersReducedMotion && !isCoarsePointer && window.innerWidth >= 720);

let width = 0;
let height = 0;
let particles = [];
let pointer = { x: 0.5, y: 0.18 };
let pendingPointer = pointer;
let pointerTicking = false;
let heroCarouselTimer;
let timelineTicking = false;

function resizeCanvas() {
  if (!canUseAmbientCanvas) return;
  const scale = Math.min(window.devicePixelRatio || 1, 2);
  width = window.innerWidth;
  height = window.innerHeight;
  canvas.width = Math.floor(width * scale);
  canvas.height = Math.floor(height * scale);
  canvas.style.width = `${width}px`;
  canvas.style.height = `${height}px`;
  ctx.setTransform(scale, 0, 0, scale, 0, 0);

  const particleCount = Math.min(46, Math.floor(width / 30));
  particles = Array.from({ length: particleCount }, () => ({
    x: Math.random() * width,
    y: Math.random() * height,
    r: 1 + Math.random() * 2.8,
    vx: -0.22 + Math.random() * 0.44,
    vy: -0.18 + Math.random() * 0.36,
    a: 0.08 + Math.random() * 0.18
  }));
}

function drawAmbient() {
  if (!canUseAmbientCanvas) return;
  ctx.clearRect(0, 0, width, height);

  const glow = ctx.createRadialGradient(
    pointer.x * width,
    pointer.y * height,
    0,
    pointer.x * width,
    pointer.y * height,
    Math.max(width, height) * 0.56
  );
  glow.addColorStop(0, "rgba(115, 168, 160, 0.25)");
  glow.addColorStop(0.42, "rgba(230, 186, 87, 0.10)");
  glow.addColorStop(1, "rgba(248, 245, 236, 0)");
  ctx.fillStyle = glow;
  ctx.fillRect(0, 0, width, height);

  particles.forEach(particle => {
    particle.x += particle.vx;
    particle.y += particle.vy;

    if (particle.x < -10) particle.x = width + 10;
    if (particle.x > width + 10) particle.x = -10;
    if (particle.y < -10) particle.y = height + 10;
    if (particle.y > height + 10) particle.y = -10;

    ctx.beginPath();
    ctx.arc(particle.x, particle.y, particle.r, 0, Math.PI * 2);
    ctx.fillStyle = `rgba(36, 77, 79, ${particle.a})`;
    ctx.fill();
  });

  requestAnimationFrame(drawAmbient);
}

function countUp(element) {
  const target = Number(element.dataset.count);
  const start = performance.now();
  const duration = 920;

  function tick(now) {
    const progress = Math.min((now - start) / duration, 1);
    const eased = 1 - Math.pow(1 - progress, 3);
    element.textContent = Math.round(target * eased);
    if (progress < 1) requestAnimationFrame(tick);
  }

  requestAnimationFrame(tick);
}

const revealObserver = new IntersectionObserver(
  entries => {
    entries.forEach(entry => {
      if (!entry.isIntersecting) return;
      const delay = entry.target.dataset.delay || 0;
      entry.target.style.setProperty("--delay", `${delay}ms`);
      entry.target.classList.add("visible");

      counters.forEach(counter => {
        if (!counter.dataset.done && entry.target.contains(counter)) {
          counter.dataset.done = "true";
          countUp(counter);
        }
      });
    });
  },
  { threshold: 0.16 }
);

function switchDemo(name, options = {}) {
  const activeTab = demoTabs.find(tab => tab.dataset.demo === name);

  demoTabs.forEach(tab => {
    const isActive = tab.dataset.demo === name;
    tab.classList.toggle("active", isActive);
    tab.setAttribute("aria-selected", String(isActive));
    tab.tabIndex = isActive ? 0 : -1;
  });

  demoScreens.forEach(screen => {
    const isActive = screen.dataset.screen === name;
    screen.classList.toggle("active", isActive);
    screen.setAttribute("aria-hidden", String(!isActive));
  });

  demoCanvas?.setAttribute("data-active-demo", name);

  if (options.scrollTab !== false && activeTab) {
    activeTab.scrollIntoView({
      behavior: prefersReducedMotion ? "auto" : "smooth",
      block: "nearest",
      inline: "center"
    });
  }
}

function setupMagneticButtons() {
  if (prefersReducedMotion || isCoarsePointer) return;

  document.querySelectorAll(".magnetic").forEach(button => {
    button.addEventListener("mousemove", event => {
      const rect = button.getBoundingClientRect();
      const x = event.clientX - rect.left - rect.width / 2;
      const y = event.clientY - rect.top - rect.height / 2;
      button.style.transform = `translate(${x * 0.07}px, ${y * 0.1}px)`;
    });

    button.addEventListener("mouseleave", () => {
      button.style.transform = "";
    });
  });
}

function updateHeroBubble() {
  if (!heroBubble) return;
  const frontCard = heroCards.find(card => card.classList.contains("is-front"));
  if (!frontCard) return;

  heroBubble.querySelector("strong").textContent = `${frontCard.dataset.kicker || ""}，${frontCard.dataset.title || ""}`;
  heroBubble.classList.remove("bubble-left-middle", "bubble-right-top", "bubble-right-middle");
  heroBubble.classList.add(frontCard.dataset.bubblePosition || "bubble-left-middle");
}

function rotateHeroCards() {
  heroCards.forEach(card => {
    if (card.classList.contains("is-front")) {
      card.classList.remove("is-front");
      card.classList.add("is-mid");
      return;
    }

    if (card.classList.contains("is-mid")) {
      card.classList.remove("is-mid");
      card.classList.add("is-back");
      return;
    }

    card.classList.remove("is-back");
    card.classList.add("is-front");
  });
  updateHeroBubble();
}

function startHeroCarousel() {
  if (prefersReducedMotion || document.hidden || heroCards.length < 3) return;
  window.clearInterval(heroCarouselTimer);
  heroCarouselTimer = window.setInterval(rotateHeroCards, 3600);
}

function updatePointer(event) {
  pendingPointer = {
    x: event.clientX / window.innerWidth,
    y: event.clientY / window.innerHeight
  };

  if (pointerTicking) return;
  pointerTicking = true;
  requestAnimationFrame(() => {
    pointerTicking = false;
    pointer = pendingPointer;
    root.style.setProperty("--mx", `${pointer.x * 100}%`);
    root.style.setProperty("--my", `${pointer.y * 100}%`);
  });
}

function updateTimelineActive() {
  timelineTicking = false;
  if (!timelineSections.length) return;

  const anchor = window.innerHeight * 0.45;
  let activeSection = timelineSections[0];

  timelineSections.forEach(section => {
    if (section.getBoundingClientRect().top <= anchor) {
      activeSection = section;
    }
  });

  timelineLinks.forEach(link => {
    link.classList.toggle("active", link.getAttribute("href") === `#${activeSection.id}`);
  });
}

function requestTimelineUpdate() {
  if (timelineTicking) return;
  timelineTicking = true;
  requestAnimationFrame(updateTimelineActive);
}

revealObserver && reveals.forEach(item => revealObserver.observe(item));
demoTabs.forEach(tab => {
  tab.addEventListener("click", () => switchDemo(tab.dataset.demo));
  tab.addEventListener("keydown", event => {
    if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return;
    event.preventDefault();

    const currentIndex = demoTabs.indexOf(tab);
    const lastIndex = demoTabs.length - 1;
    let nextIndex = currentIndex;

    if (event.key === "ArrowLeft") nextIndex = currentIndex <= 0 ? lastIndex : currentIndex - 1;
    if (event.key === "ArrowRight") nextIndex = currentIndex >= lastIndex ? 0 : currentIndex + 1;
    if (event.key === "Home") nextIndex = 0;
    if (event.key === "End") nextIndex = lastIndex;

    demoTabs[nextIndex]?.focus();
    switchDemo(demoTabs[nextIndex]?.dataset.demo);
  });
});
setupMagneticButtons();
if (canUseAmbientCanvas) {
  resizeCanvas();
} else if (canvas) {
  canvas.hidden = true;
}
switchDemo(demoTabs.find(tab => tab.classList.contains("active"))?.dataset.demo || "voice", { scrollTab: false });
updateHeroBubble();
startHeroCarousel();

heroStack?.addEventListener("mouseenter", () => window.clearInterval(heroCarouselTimer));
heroStack?.addEventListener("mouseleave", startHeroCarousel);
window.addEventListener("scroll", requestTimelineUpdate, { passive: true });
window.addEventListener("resize", requestTimelineUpdate, { passive: true });
document.addEventListener("visibilitychange", () => {
  if (document.hidden) {
    window.clearInterval(heroCarouselTimer);
    return;
  }
  startHeroCarousel();
});
updateTimelineActive();

if (canUseAmbientCanvas) {
  window.addEventListener("resize", resizeCanvas, { passive: true });
  window.addEventListener("pointermove", updatePointer, { passive: true });
  requestAnimationFrame(drawAmbient);
}
