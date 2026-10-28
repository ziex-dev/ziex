// Top-bar docs search over the index the sidebar embeds (built from the sidebars at comptime).

type Entry = { t: string; g: string; h: string };

const MAX_RESULTS = 8;

function score(entry: Entry, terms: string[]): number {
  const title = entry.t.toLowerCase();
  const group = entry.g.toLowerCase();
  let total = 0;
  for (const term of terms) {
    if (title === term) total += 100;
    else if (title.startsWith(term)) total += 50;
    else if (title.includes(term)) total += 20;
    else if (group.includes(term)) total += 5;
    else return 0;
  }
  return total;
}

export function setupDocsSearch() {
  const input = document.getElementById("docs-search") as HTMLInputElement | null;
  const list = document.getElementById("docs-search-results") as HTMLUListElement | null;
  const data = document.getElementById("docs-search-index");
  if (!input || !list || !data) return;

  let entries: Entry[] = [];
  try {
    entries = JSON.parse(data.textContent || "[]");
  } catch {
    return;
  }

  let results: Entry[] = [];
  let selected = 0;

  const close = () => {
    list.hidden = true;
    input.setAttribute("aria-expanded", "false");
  };

  const render = () => {
    list.replaceChildren();
    if (results.length === 0) {
      const empty = document.createElement("li");
      empty.className = "top-bar-search-empty";
      empty.textContent = "No results";
      list.append(empty);
    }
    results.forEach((entry, i) => {
      const item = document.createElement("li");
      item.setAttribute("role", "option");
      item.setAttribute("aria-selected", String(i === selected));
      const link = document.createElement("a");
      link.href = entry.h;
      link.className = "top-bar-search-result";
      const title = document.createElement("span");
      title.className = "top-bar-search-result-title";
      title.textContent = entry.t;
      const group = document.createElement("span");
      group.className = "top-bar-search-result-group";
      group.textContent = entry.g;
      link.append(title, group);
      link.addEventListener("click", close);
      item.append(link);
      list.append(item);
    });
    list.hidden = false;
    input.setAttribute("aria-expanded", "true");
  };

  const search = () => {
    const terms = input.value.toLowerCase().split(/\s+/).filter(Boolean);
    if (terms.length === 0) return close();
    results = entries
      .map((entry) => ({ entry, s: score(entry, terms) }))
      .filter((r) => r.s > 0)
      .sort((a, b) => b.s - a.s)
      .slice(0, MAX_RESULTS)
      .map((r) => r.entry);
    selected = 0;
    render();
  };

  input.addEventListener("input", search);
  input.addEventListener("focus", () => input.value && search());
  input.addEventListener("keydown", (e) => {
    if (e.key === "Escape") {
      close();
      input.blur();
    } else if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      if (results.length === 0) return;
      e.preventDefault();
      const step = e.key === "ArrowDown" ? 1 : -1;
      selected = (selected + step + results.length) % results.length;
      render();
    } else if (e.key === "Enter" && results[selected]) {
      e.preventDefault();
      close();
      window.location.href = results[selected].h;
    }
  });

  document.addEventListener("click", (e) => {
    if (!(e.target instanceof Node) || !input.parentElement?.contains(e.target)) close();
  });

  document.addEventListener("keydown", (e) => {
    const target = e.target as HTMLElement | null;
    const typing = target && (target.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(target.tagName));
    if ((e.key === "/" && !typing) || (e.key === "k" && (e.metaKey || e.ctrlKey))) {
      e.preventDefault();
      input.focus();
      input.select();
    }
  });
}
