const start = document.querySelector('#start');
const notice = document.querySelector('#notice');
const list = document.querySelector('#jobs');
const streams = new Set();

start.addEventListener('click', async () => {
  start.disabled = true;
  notice.textContent = '';
  try {
    const response = await fetch('/jobs', { method: 'POST' });
    if (response.status === 401) { location.assign('/login'); return; }
    if (!response.ok) throw new Error(await response.text());
    const { id } = await response.json();
    document.querySelector('#empty')?.remove();
    watch(id);
  } catch (error) { notice.textContent = error.message; }
  finally { start.disabled = false; }
});

function watch(id) {
  const card = document.createElement('article');
  card.className = 'job';
  card.innerHTML = '<header><strong></strong><span class="tag">Connected</span></header><h2>0%</h2><progress max="100" value="0" aria-label="Job progress"></progress><p>Waiting for the first step…</p>';
  card.querySelector('strong').textContent = `Job ${id}`;
  list.prepend(card);
  // Keep the browser view bounded too. Old cards no longer receive events.
  if (list.children.length > 8) {
    const retired = list.lastElementChild;
    retired.dispatchEvent(new Event('retire'));
    retired.remove();
  }
  const source = new EventSource(`/jobs/${encodeURIComponent(id)}/events`);
  streams.add(source);
  const tag = card.querySelector('.tag');
  const message = card.querySelector('p');
  const close = () => { source.close(); streams.delete(source); };
  card.addEventListener('retire', close, { once: true });
  const update = event => {
    const value = JSON.parse(event.data);
    card.querySelector('h2').textContent = `${value.progress}%`;
    card.querySelector('progress').value = value.progress;
    tag.textContent = value.done ? 'Complete' : 'Working';
    message.textContent = value.done ? 'All done. Every step arrived from the server.' : `Event ${event.lastEventId} received. No polling required.`;
  };
  source.addEventListener('progress', update);
  source.addEventListener('done', event => { update(event); close(); });
  source.addEventListener('reset', event => {
    update(event); close(); tag.textContent = 'Replay gap';
    message.textContent = 'The server sent its latest snapshot. Start a new job for a complete event history.';
  });
  for (const event of ['session-expired', 'expired']) source.addEventListener(event, () => {
    close(); tag.textContent = 'Closed';
    message.textContent = event === 'session-expired' ? 'Your session ended. Sign in again to continue.' : 'This job expired. Start a new job.';
  });
  let reconnects = 0;
  source.onerror = () => {
    // Native EventSource retains Last-Event-ID. Limit retries across this stream's lifetime.
    if (source.readyState === EventSource.CONNECTING && reconnects < 3) {
      reconnects += 1;
      tag.textContent = 'Reconnecting';
      message.textContent = `Reconnecting after the last received event (attempt ${reconnects} of 3)…`;
      return;
    }
    close(); tag.textContent = 'Disconnected';
    message.textContent = 'The stream ended. Start a new job to try again.';
  };
}

addEventListener('pagehide', () => { for (const stream of streams) stream.close(); });
