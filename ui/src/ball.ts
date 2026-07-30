/** Entry point of the mascot window (`index.html`). */

import { mount } from 'svelte';
import './app.css';
import BallApp from './BallApp.svelte';
import { installErrorReporting } from './lib/errors';

// Before mounting: an exception thrown during the first render is exactly the
// kind that leaves a blank window with nothing in the log.
installErrorReporting('ball');

const target = document.getElementById('app');
if (!target) throw new Error('mount target #app is missing from index.html');

export default mount(BallApp, { target });
