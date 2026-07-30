(() => {
  const outreachPanel = document.getElementById("outreachPanel");
  const pageFooter = document.querySelector("body > footer");
  if (outreachPanel && pageFooter && outreachPanel.nextElementSibling !== pageFooter) {
    pageFooter.before(outreachPanel);
  }

  const targetMap = {
    kpiUnfilled5: ["unfilledPanel"],
    kpiLarge: ["largePanel"],
    kpiFilled: ["pipelinePanel"],
    kpiApproval: ["approvalPanel"],
    kpiAutoOff: ["businessPanel", "unfilledPanel"],
    kpiHighRisk: ["outreachPanel"],
    kpiMedRisk: ["outreachPanel"],
    kpiNeedsBonus: ["bonusPanel", "businessPanel"],
    kpiHealthy: ["shiftHealthPanel"],
    kpiShifts: ["pipelinePanel"],
    kpiUnfilled: ["businessPanel", "pipelinePanel"],
    kpiUrgent: ["outreachPanel"],
    kpiWatch: ["outreachPanel"],
    kpiUnverified: ["outreachPanel"],
    kpiNeedsFill: ["businessPanel"]
  };

  const prefersReducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

  function resolveTarget(candidates) {
    return candidates.map(id => document.getElementById(id)).find(Boolean);
  }

  function activateCard(card) {
    const target = document.getElementById(card.dataset.dashboardTarget);
    if (!target) return;

    if (target.tagName === "DETAILS") target.open = true;
    target.classList.remove("dashboard-target-flash");
    void target.offsetWidth;
    target.classList.add("dashboard-target-flash");
    target.scrollIntoView({
      behavior: prefersReducedMotion.matches ? "auto" : "smooth",
      block: "start"
    });
    window.setTimeout(() => target.classList.remove("dashboard-target-flash"), 850);
  }

  document.querySelectorAll(".kpi-card").forEach(card => {
    const value = card.querySelector(".kpi-value[id]");
    const target = value && resolveTarget(targetMap[value.id] || []);
    if (!target) return;

    const label = card.querySelector(".kpi-label")?.textContent?.trim() || "metric";
    card.dataset.dashboardTarget = target.id;
    card.tabIndex = 0;
    card.setAttribute("role", "button");
    card.setAttribute("aria-label", `${label}: open related details`);
    card.title = "Open related details";

    card.addEventListener("click", () => activateCard(card));
    card.addEventListener("keydown", event => {
      if (event.key !== "Enter" && event.key !== " ") return;
      event.preventDefault();
      activateCard(card);
    });
  });

  // Keep the containing dashboard hub fitted to the embedded page as charts,
  // images, filters, and collapsible panels change its content height.
  if (window.self !== window.top) {
    const reportFrameHeight = () => {
      const height = Math.max(
        document.documentElement.scrollHeight,
        document.body ? document.body.scrollHeight : 0
      );
      window.parent.postMessage({ type: "qwick:frame-height", height }, "*");
    };

    window.addEventListener("load", reportFrameHeight);
    window.addEventListener("resize", reportFrameHeight);
    window.addEventListener("message", event => {
      if (
        event.source === window.parent &&
        event.data &&
        event.data.type === "qwick:request-frame-height"
      ) {
        reportFrameHeight();
      }
    });

    if ("ResizeObserver" in window) {
      window.__qwickFrameResizeObserver = new ResizeObserver(reportFrameHeight);
      window.__qwickFrameResizeObserver.observe(document.documentElement);
    }

    requestAnimationFrame(reportFrameHeight);
  }
})();
