/// <reference types="vite/client" />

declare module "@novnc/novnc" {
  export default class RFB extends EventTarget {
    constructor(target: HTMLElement | null, url: string, options?: any);
    scaleViewport: boolean;
    resizeSession: boolean;
    clipViewport: boolean;
    focusOnClick: boolean;
    background: string;
    viewOnly: boolean;
    qualityLevel: number;
    compressionLevel: number;
    sendKey(keysym: number, code: string, down?: boolean): void;
    sendCredentials(credentials: any): void;
    disconnect(): void;
  }
}
