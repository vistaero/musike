// The deployment target transpiles syntax. These runtime APIs arrived after WebKit in iOS 12.
if (import.meta.env.MUSIKE_LEGACY_IOS) {
  if (typeof globalThis === "undefined") Object.defineProperty(window, "globalThis", { value: window });
  if (!Array.prototype.at) {
    Object.defineProperty(Array.prototype, "at", {
      configurable: true, writable: true,
      value(this: unknown[], index: number) {
        const offset = Math.trunc(Number(index)) || 0;
        const position = offset < 0 ? this.length + offset : offset;
        return position >= 0 && position < this.length ? this[position] : undefined;
      },
    });
  }
  if (!Array.prototype.findLast) {
    Object.defineProperty(Array.prototype, "findLast", {
      configurable: true, writable: true,
      value(this: unknown[], predicate: (value: unknown, index: number, array: unknown[]) => boolean, thisArg?: unknown) {
        for (let index = this.length - 1; index >= 0; index--) {
          const value = this[index];
          if (predicate.call(thisArg, value, index, this)) return value;
        }
        return undefined;
      },
    });
  }
  if (!String.prototype.replaceAll) {
    Object.defineProperty(String.prototype, "replaceAll", {
      configurable: true, writable: true,
      value(this: string, search: string | RegExp, replacement: string | ((substring: string, ...args: unknown[]) => string)) {
        const pattern = typeof search === "string"
          ? new RegExp(search.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "g")
          : search;
        if (!pattern.global) throw new TypeError("replaceAll requires a global regular expression");
        return typeof replacement === "string" ? this.replace(pattern, replacement) : this.replace(pattern, replacement);
      },
    });
  }
  if (!Object.fromEntries) {
    Object.defineProperty(Object, "fromEntries", {
      configurable: true, writable: true,
      value(entries: Iterable<[PropertyKey, unknown]>) {
        const object = {};
        for (const [key, value] of entries) {
          Object.defineProperty(object, key, { value, enumerable: true, configurable: true, writable: true });
        }
        return object;
      },
    });
  }
  if (!crypto.randomUUID) {
    Object.defineProperty(crypto, "randomUUID", {
      configurable: true,
      value() {
        const bytes = crypto.getRandomValues(new Uint8Array(16));
        bytes[6] = (bytes[6]! & 15) | 64;
        bytes[8] = (bytes[8]! & 63) | 128;
        const hex = Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
        return [hex.slice(0, 8), hex.slice(8, 12), hex.slice(12, 16), hex.slice(16, 20), hex.slice(20)].join("-");
      },
    });
  }
  if (!Element.prototype.scrollTo) {
    Object.defineProperty(Element.prototype, "scrollTo", {
      configurable: true, writable: true,
      value(this: Element, options: ScrollToOptions | number, y?: number) {
        if (typeof options === "number") { this.scrollLeft = options; this.scrollTop = y ?? 0; }
        else {
          if (options.left != null) this.scrollLeft = options.left;
          if (options.top != null) this.scrollTop = options.top;
        }
      },
    });
  }
  if (!Blob.prototype.text) {
    Object.defineProperty(Blob.prototype, "text", {
      configurable: true, writable: true,
      value(this: Blob) {
        return new Promise<string>((resolve, reject) => {
          const reader = new FileReader();
          reader.onload = () => resolve(String(reader.result));
          reader.onerror = () => reject(reader.error);
          reader.readAsText(this);
        });
      },
    });
  }
}
