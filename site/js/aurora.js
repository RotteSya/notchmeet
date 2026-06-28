/* notchmeet — "Living Metal" aurora.
 * A double-domain-warped fBm field in the brand periwinkles, rendered live in WebGL.
 * Brightest upper-centre (aligned with the notch above), falling to near-black at the
 * reading column so type stays crisp. Hash dither in-shader kills banding — no blurry
 * coloured halos, just a slow deep aurora that breathes.
 *
 *   window.NMAurora.init(canvas, opts?) -> { destroy, setPointer, setIntensity }
 */
(function () {
  const VERT = `
    attribute vec2 p;
    void main(){ gl_Position = vec4(p, 0.0, 1.0); }
  `;

  const FRAG = `
    precision highp float;
    uniform vec2  u_res;
    uniform float u_time;
    uniform vec2  u_ptr;       // pointer in 0..1, y down
    uniform float u_intensity; // 0..1 master
    uniform float u_accentMix; // hue lean

    // -- brand palette (sRGB-ish, linearised by feel) --
    const vec3 OBSIDIAN = vec3(0.024, 0.027, 0.043);
    const vec3 ACC      = vec3(0.490, 0.635, 1.000); // #7da2ff
    const vec3 ACC_LO   = vec3(0.345, 0.471, 0.910); // #5878e8
    const vec3 SHEEN    = vec3(0.800, 0.859, 1.000); // #ccdbff

    // hash + value noise
    float hash(vec2 p){
      p = fract(p * vec2(123.34, 456.21));
      p += dot(p, p + 34.345);
      return fract(p.x * p.y);
    }
    float noise(vec2 p){
      vec2 i = floor(p), f = fract(p);
      vec2 u = f*f*(3.0-2.0*f);
      float a = hash(i);
      float b = hash(i + vec2(1.0,0.0));
      float c = hash(i + vec2(0.0,1.0));
      float d = hash(i + vec2(1.0,1.0));
      return mix(mix(a,b,u.x), mix(c,d,u.x), u.y);
    }
    float fbm(vec2 p){
      float v = 0.0, a = 0.5;
      mat2 m = mat2(1.6, 1.2, -1.2, 1.6);
      for(int i=0;i<6;i++){ v += a*noise(p); p = m*p; a *= 0.5; }
      return v;
    }

    void main(){
      vec2 uv = gl_FragCoord.xy / u_res.xy;
      float yt = uv.y;                      // NOTE: in GL, 1.0 = top of canvas, 0.0 = bottom
      vec2 st = uv;
      st.x *= u_res.x / u_res.y;            // aspect-correct
      float t = u_time * 0.045;

      // pointer parallax — the field leans gently toward the cursor
      vec2 par = (u_ptr - 0.5) * vec2(0.22, -0.22);

      // ---- double domain warp ----
      vec2 q;
      q.x = fbm(st * 1.4 + par + vec2(0.0, t));
      q.y = fbm(st * 1.4 + par + vec2(5.2, -t*0.8) + 1.7);

      vec2 r;
      r.x = fbm(st * 1.9 + q * 2.4 + vec2(1.7 + t*1.2, 9.2));
      r.y = fbm(st * 1.9 + q * 2.4 + vec2(8.3, 2.8 - t));

      float f = fbm(st * 1.7 + r * 2.2 + par);
      float aurora = pow(f, 1.5);          // higher exponent → crests of light, not flat fog

      // ---- vertical light field: a bright crown behind the notch, falling to obsidian ----
      float dx = uv.x - 0.5;
      // tight luminous crown hugging the very top-centre, where the real notch sits
      float glow = exp(-pow((yt - 1.0) * 2.15, 2.0)) * exp(-dx*dx * 2.5);
      float fall = smoothstep(-0.04, 1.06, yt);                 // deep near-black low on the canvas

      // obsidian dominates; the aurora reads as cool crests, never a haze
      float band = clamp(aurora * 0.64 + glow * 1.02, 0.0, 1.3) * mix(0.05, 1.0, fall);
      band = pow(clamp(band, 0.0, 1.0), 1.46);

      // colour: lean from the grounded ACC_LO into ACC on the crests; sheen specular near the top
      vec3 body = mix(ACC_LO, ACC, clamp(r.x * 0.82 + 0.16 + u_accentMix, 0.0, 1.0));
      vec3 col = OBSIDIAN;
      col = mix(col, body, clamp(band * 0.84, 0.0, 0.95));
      col += SHEEN * pow(clamp(glow * (0.40 + aurora), 0.0, 1.0), 1.7) * 0.52;

      // darken a broad central reading column so type stays crisp
      float legib = smoothstep(0.74, 0.16, abs(yt - 0.42));
      col *= mix(1.0, 0.64, legib * 0.62);

      // gentle side vignette → the light stays a central, deliberate event
      col *= mix(1.0, 0.80, smoothstep(0.30, 0.02, 0.5 - abs(dx)));

      // master intensity
      col = mix(OBSIDIAN, col, clamp(u_intensity, 0.0, 1.0));

      // in-shader triangular-PDF dither (the anti-band device)
      float d = (hash(gl_FragCoord.xy + u_time) + hash(gl_FragCoord.yx - u_time) - 1.0) / 255.0;
      col += d;

      gl_FragColor = vec4(col, 1.0);
    }
  `;

  function compile(gl, type, src) {
    const s = gl.createShader(type);
    gl.shaderSource(s, src);
    gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) {
      console.warn("NMAurora shader:", gl.getShaderInfoLog(s));
    }
    return s;
  }

  function init(canvas, opts) {
    opts = opts || {};
    window.__nmAuroraDiag = { stage: "start", frames: 0 };
    const gl =
      canvas.getContext("webgl", { antialias: false, alpha: false, premultipliedAlpha: false, preserveDrawingBuffer: true }) ||
      canvas.getContext("experimental-webgl");
    if (!gl) {
      window.__nmAuroraDiag.stage = "no-gl";
      // graceful fallback — paint the CSS aurora colours so the hero is never empty
      canvas.style.background =
        "radial-gradient(120% 80% at 50% -10%, rgba(125,162,255,0.22), transparent 60%)," +
        "radial-gradient(90% 70% at 12% 8%, rgba(88,120,232,0.20), transparent 55%), #06070b";
      return { destroy() {}, setPointer() {}, setIntensity() {} };
    }

    const prog = gl.createProgram();
    gl.attachShader(prog, compile(gl, gl.VERTEX_SHADER, VERT));
    gl.attachShader(prog, compile(gl, gl.FRAGMENT_SHADER, FRAG));
    gl.linkProgram(prog);
    gl.useProgram(prog);

    const buf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
    const loc = gl.getAttribLocation(prog, "p");
    gl.enableVertexAttribArray(loc);
    gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);

    const u_res = gl.getUniformLocation(prog, "u_res");
    const u_time = gl.getUniformLocation(prog, "u_time");
    const u_ptr = gl.getUniformLocation(prog, "u_ptr");
    const u_intensity = gl.getUniformLocation(prog, "u_intensity");
    const u_accentMix = gl.getUniformLocation(prog, "u_accentMix");

    let dpr = Math.min(window.devicePixelRatio || 1, 2);
    function resize() {
      const w = canvas.clientWidth || canvas.offsetWidth || 1;
      const h = canvas.clientHeight || canvas.offsetHeight || 1;
      canvas.width = Math.max(1, Math.floor(w * dpr));
      canvas.height = Math.max(1, Math.floor(h * dpr));
      gl.viewport(0, 0, canvas.width, canvas.height);
    }
    resize();
    const ro = new ResizeObserver(resize);
    ro.observe(canvas);

    // pointer — eased toward target so parallax never snaps
    let ptr = { x: 0.5, y: 0.32 };
    let target = { x: 0.5, y: 0.32 };
    let intensity = opts.intensity != null ? opts.intensity : 1.0;
    let intensityTarget = intensity;
    const accentMix = opts.accentMix != null ? opts.accentMix : 0.0;

    const reduce = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    const start = performance.now();
    let raf = 0;
    let last = start;

    function frame(now) {
      const dt = Math.min((now - last) / 1000, 0.05);
      last = now;
      ptr.x += (target.x - ptr.x) * Math.min(dt * 3.2, 1);
      ptr.y += (target.y - ptr.y) * Math.min(dt * 3.2, 1);
      intensity += (intensityTarget - intensity) * Math.min(dt * 2.5, 1);

      const t = reduce ? 12.0 : (now - start) / 1000;
      gl.uniform2f(u_res, canvas.width, canvas.height);
      gl.uniform1f(u_time, t);
      gl.uniform2f(u_ptr, ptr.x, ptr.y);
      gl.uniform1f(u_intensity, intensity);
      gl.uniform1f(u_accentMix, accentMix);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
      window.__nmAuroraDiag.frames++;

      if (!reduce) raf = requestAnimationFrame(frame);
    }
    raf = requestAnimationFrame(frame);
    window.__nmAuroraDiag.stage = "running";
    // Paint one frame synchronously — rAF is suspended while the tab/iframe is hidden, so this
    // guarantees the canvas is never blank before the loop resumes on becoming visible.
    gl.uniform2f(u_res, canvas.width, canvas.height);
    gl.uniform1f(u_time, 6.0);
    gl.uniform2f(u_ptr, ptr.x, ptr.y);
    gl.uniform1f(u_intensity, intensity);
    gl.uniform1f(u_accentMix, accentMix);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
    window.__nmAuroraDiag.frames++;
    // when the page becomes visible again, make sure the loop is ticking
    const onVis = () => { if (!document.hidden && !reduce) { last = performance.now(); cancelAnimationFrame(raf); raf = requestAnimationFrame(frame); } };
    document.addEventListener("visibilitychange", onVis);
    if (reduce) frame(performance.now()); // one paint

    return {
      destroy() {
        cancelAnimationFrame(raf);
        ro.disconnect();
        document.removeEventListener("visibilitychange", onVis);
      },
      setPointer(x, y) {
        target.x = x;
        target.y = y;
      },
      setIntensity(v) {
        intensityTarget = v;
      },
    };
  }

  window.NMAurora = { init };
})();
