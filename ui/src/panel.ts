/** Entry point of the notebook window (`panel.html`). */

import { mount } from 'svelte';
import './app.css';
import PanelApp from './PanelApp.svelte';
import { installErrorReporting } from './lib/errors';

installErrorReporting('panel');

const target = document.getElementById('app');
if (!target) throw new Error('mount target #app is missing from panel.html');

export default mount(PanelApp, { target });
