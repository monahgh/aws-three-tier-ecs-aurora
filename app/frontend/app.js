// Minimal SPA: talks to /api/* on the same CloudFront domain (no CORS needed).

const itemsEl = document.getElementById('items');
const statusEl = document.getElementById('add-status');

async function loadItems() {
  itemsEl.innerHTML = '<li>Loading...</li>';
  try {
    const res = await fetch('/api/items');
    const items = await res.json();
    if (!res.ok) throw new Error(items.error || res.statusText);
    itemsEl.innerHTML = '';
    if (items.length === 0) itemsEl.innerHTML = '<li>No items yet.</li>';
    for (const item of items) {
      const li = document.createElement('li');
      li.textContent = `#${item.id} ${item.name} (${new Date(item.created_at).toLocaleString()})`;
      itemsEl.appendChild(li);
    }
  } catch (e) {
    itemsEl.innerHTML = `<li>Error: ${e.message}</li>`;
  }
}

document.getElementById('add-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  const input = document.getElementById('item-name');
  statusEl.textContent = 'Saving...';
  try {
    const res = await fetch('/api/items', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name: input.value }),
    });
    const body = await res.json();
    if (!res.ok) throw new Error(body.error || res.statusText);
    statusEl.textContent = `Saved item #${body.id}`;
    input.value = '';
    setTimeout(loadItems, 500);
  } catch (e) {
    statusEl.textContent = `Error: ${e.message}`;
  }
});

document.getElementById('refresh').addEventListener('click', loadItems);

document.getElementById('whoami').addEventListener('click', async () => {
  const out = document.getElementById('whoami-out');
  out.textContent = 'Calling...';
  try {
    const res = await fetch('/api/whoami');
    out.textContent = JSON.stringify(await res.json(), null, 2);
  } catch (e) {
    out.textContent = `Error: ${e.message}`;
  }
});

loadItems();
