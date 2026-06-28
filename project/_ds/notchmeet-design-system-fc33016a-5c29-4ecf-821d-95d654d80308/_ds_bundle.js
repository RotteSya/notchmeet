/* @ds-bundle: {"format":3,"namespace":"NotchmeetDesignSystem_fc3301","components":[{"name":"Badge","sourcePath":"components/core/Badge.jsx"},{"name":"Button","sourcePath":"components/core/Button.jsx"},{"name":"Card","sourcePath":"components/core/Card.jsx"},{"name":"Kicker","sourcePath":"components/core/Kicker.jsx"},{"name":"Field","sourcePath":"components/forms/Field.jsx"},{"name":"Segmented","sourcePath":"components/forms/Segmented.jsx"},{"name":"Select","sourcePath":"components/forms/Select.jsx"},{"name":"Toggle","sourcePath":"components/forms/Toggle.jsx"},{"name":"ProgressRail","sourcePath":"components/notch/ProgressRail.jsx"},{"name":"StatusJewel","sourcePath":"components/notch/StatusJewel.jsx"}],"sourceHashes":{"components/core/Badge.jsx":"6568afd7f593","components/core/Button.jsx":"38121d0ac8c3","components/core/Card.jsx":"e226fdf4198f","components/core/Kicker.jsx":"638dfcd187a5","components/forms/Field.jsx":"b930207247bc","components/forms/Segmented.jsx":"9aa7c039033b","components/forms/Select.jsx":"accab1d53102","components/forms/Toggle.jsx":"ac4f2b9b45df","components/notch/ProgressRail.jsx":"93f51bab9e1f","components/notch/StatusJewel.jsx":"1e6a55769724","ui_kits/notch/NotchPanel.jsx":"856776721dcf","ui_kits/onboarding/Onboarding.jsx":"323ca37a9bb4","ui_kits/settings/Settings.jsx":"252519e0b7f7"},"inlinedExternals":[],"unexposedExports":[]} */

(() => {

const __ds_ns = (window.NotchmeetDesignSystem_fc3301 = window.NotchmeetDesignSystem_fc3301 || {});

const __ds_scope = {};

(__ds_ns.__errors = __ds_ns.__errors || []);

// components/core/Badge.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
/**
 * notchmeet Badge — a small status pill. `active` is the periwinkle "in use" badge (filled,
 * like the script library's 使用中 marker); `tone` variants cover neutral / recording / warning.
 */
function Badge({
  children,
  tone = "neutral",
  icon,
  style,
  ...rest
}) {
  const tones = {
    neutral: {
      color: "var(--text-secondary)",
      bg: "rgba(255,255,255,0.06)",
      border: "rgba(255,255,255,0.12)"
    },
    active: {
      color: "var(--text-on-accent)",
      bg: "var(--grad-key)",
      border: "transparent"
    },
    accent: {
      color: "var(--accent)",
      bg: "rgba(125,162,255,0.12)",
      border: "rgba(125,162,255,0.32)"
    },
    recording: {
      color: "var(--nm-recording)",
      bg: "rgba(255,69,58,0.12)",
      border: "rgba(255,69,58,0.40)"
    },
    warning: {
      color: "var(--nm-warning)",
      bg: "rgba(255,159,30,0.12)",
      border: "rgba(255,159,30,0.38)"
    }
  }[tone];
  return /*#__PURE__*/React.createElement("span", _extends({
    style: {
      display: "inline-flex",
      alignItems: "center",
      gap: "var(--space-2)",
      fontFamily: "var(--font-sans)",
      fontSize: "10.5px",
      fontWeight: "var(--weight-semibold)",
      letterSpacing: "0.2px",
      lineHeight: 1,
      padding: "3px 8px",
      borderRadius: "var(--radius-pill)",
      color: tones.color,
      background: tones.bg,
      border: `0.75px solid ${tones.border}`,
      ...style
    }
  }, rest), icon && /*#__PURE__*/React.createElement("i", {
    "data-lucide": icon,
    style: {
      width: "11px",
      height: "11px"
    },
    "aria-hidden": "true"
  }), children);
}
Object.assign(__ds_scope, { Badge });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/core/Badge.jsx", error: String((e && e.message) || e) }); }

// components/core/Button.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
/**
 * notchmeet Button — a hand-built key in the obsidian + edge-of-light language.
 * Primary is a convex periwinkle key (top sheen → body, white top-edge hairline, a grounded
 * colored shadow). Secondary/ghost is hairline-glass. Destructive is red-edged glass. Plain is
 * barely-there text. Press shrinks to 97%; accent keys brighten on hover.
 */
function Button({
  children,
  variant = "secondary",
  size = "md",
  icon,
  // a Lucide icon name (substitutes SF Symbols) OR a node
  iconRight,
  disabled = false,
  full = false,
  onClick,
  style,
  ...rest
}) {
  const [hover, setHover] = React.useState(false);
  const [press, setPress] = React.useState(false);
  const pads = {
    sm: {
      padding: "5px 12px",
      font: "12px"
    },
    md: {
      padding: "9px 18px",
      font: "var(--text-control)"
    },
    lg: {
      padding: "12px 26px",
      font: "15px"
    }
  }[size];
  const base = {
    display: "inline-flex",
    alignItems: "center",
    justifyContent: "center",
    gap: "var(--space-3)",
    width: full ? "100%" : "auto",
    fontFamily: "var(--font-sans)",
    fontSize: pads.font,
    fontWeight: variant === "primary" ? "var(--weight-semibold)" : "var(--weight-medium)",
    letterSpacing: "var(--tracking-cta)",
    padding: pads.padding,
    borderRadius: variant === "plain" ? "var(--radius-xs)" : "var(--radius-xl)",
    border: "0.75px solid transparent",
    cursor: disabled ? "default" : "pointer",
    opacity: disabled ? 0.55 : 1,
    transform: press && !disabled ? "scale(var(--press-scale))" : "scale(1)",
    transition: "var(--transition-control)",
    userSelect: "none",
    WebkitFontSmoothing: "antialiased",
    whiteSpace: "nowrap"
  };
  const skins = {
    primary: {
      color: "var(--text-on-accent)",
      backgroundImage: "var(--grad-key)",
      borderImage: "var(--grad-edge-key) 1",
      boxShadow: hover ? "var(--shadow-key-hover)" : "var(--shadow-key)",
      filter: hover ? "brightness(var(--hover-brighten))" : "none"
    },
    secondary: {
      color: hover ? "var(--text-primary)" : "rgba(255,255,255,0.88)",
      backgroundColor: hover ? "var(--surface-card-hover)" : "var(--surface-card)",
      borderColor: hover ? "rgba(255,255,255,0.22)" : "rgba(255,255,255,0.14)",
      boxShadow: "var(--shadow-control)"
    },
    destructive: {
      color: "var(--nm-destructive)",
      backgroundColor: hover ? "rgba(255,79,69,0.14)" : "rgba(255,79,69,0.06)",
      borderColor: hover ? "rgba(255,79,69,0.78)" : "rgba(255,79,69,0.40)"
    },
    plain: {
      color: hover ? "var(--text-primary)" : "var(--text-secondary)",
      backgroundColor: hover ? "rgba(255,255,255,0.06)" : "transparent"
    }
  };
  const iconEl = name => typeof name === "string" ? /*#__PURE__*/React.createElement("i", {
    "data-lucide": name,
    style: {
      width: "1em",
      height: "1em",
      display: "inline-flex"
    },
    "aria-hidden": "true"
  }) : name;
  return /*#__PURE__*/React.createElement("button", _extends({
    type: "button",
    disabled: disabled,
    onClick: disabled ? undefined : onClick,
    onMouseEnter: () => setHover(true),
    onMouseLeave: () => {
      setHover(false);
      setPress(false);
    },
    onMouseDown: () => setPress(true),
    onMouseUp: () => setPress(false),
    style: {
      ...base,
      ...skins[variant],
      ...style
    }
  }, rest), icon && iconEl(icon), children && /*#__PURE__*/React.createElement("span", null, children), iconRight && iconEl(iconRight));
}
Object.assign(__ds_scope, { Button });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/core/Button.jsx", error: String((e && e.message) || e) }); }

// components/core/Card.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
/**
 * notchmeet Card — a floating obsidian glass panel: dark fill, a top sheen, a hairline that
 * brightens at the top edge (light from above), an additive dither to kill banding, and an
 * optional grounded layered shadow. The base surface for settings rows, onboarding panels,
 * and the expanded notch body.
 */
function Card({
  children,
  elevated = true,
  padding = "var(--space-7)",
  style,
  ...rest
}) {
  return /*#__PURE__*/React.createElement("div", _extends({
    style: {
      position: "relative",
      backgroundColor: "rgba(0,0,0,0.22)",
      backgroundImage: "var(--grad-sheen)",
      borderRadius: "var(--radius-card)",
      border: "0.75px solid transparent",
      borderImage: "var(--grad-edge-glass) 1",
      boxShadow: elevated ? "var(--shadow-card)" : "none",
      padding,
      overflow: "hidden",
      ...style
    }
  }, rest), /*#__PURE__*/React.createElement("span", {
    style: {
      content: '""',
      position: "absolute",
      inset: 0,
      backgroundImage: "var(--dither-tile)",
      backgroundRepeat: "repeat",
      mixBlendMode: "plus-lighter",
      opacity: "var(--dither-opacity)",
      pointerEvents: "none",
      borderRadius: "inherit"
    },
    "aria-hidden": "true"
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      position: "relative"
    }
  }, children));
}
Object.assign(__ds_scope, { Card });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/core/Card.jsx", error: String((e && e.message) || e) }); }

// components/core/Kicker.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
/**
 * notchmeet Kicker — a tiny uppercase, tracked section label with a leading periwinkle tick of
 * light. The one place the system uses uppercase. Used above onboarding headlines and settings
 * section titles.
 */
function Kicker({
  children,
  tick = true,
  style,
  ...rest
}) {
  return /*#__PURE__*/React.createElement("div", _extends({
    style: {
      display: "inline-flex",
      alignItems: "center",
      gap: "var(--space-3)",
      ...style
    }
  }, rest), tick && /*#__PURE__*/React.createElement("span", {
    style: {
      width: "14px",
      height: "2.5px",
      borderRadius: "var(--radius-pill)",
      background: "var(--accent)",
      boxShadow: "0 0 6px rgba(125,162,255,0.6)"
    }
  }), /*#__PURE__*/React.createElement("span", {
    style: {
      fontFamily: "var(--font-sans)",
      fontSize: "var(--text-kicker)",
      fontWeight: "var(--weight-semibold)",
      letterSpacing: "var(--tracking-kicker)",
      textTransform: "uppercase",
      color: "var(--accent)"
    }
  }, children));
}
Object.assign(__ds_scope, { Kicker });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/core/Kicker.jsx", error: String((e && e.message) || e) }); }

// components/forms/Field.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
/**
 * notchmeet Field — an obsidian well (recessed, inset top-shadow) with an accent focus bloom:
 * on focus the hairline border thickens to periwinkle and a soft accent glow rings the field.
 * Supports a secure variant (API keys) and a monospaced variant.
 */
function Field({
  value,
  defaultValue,
  onChange,
  placeholder,
  type = "text",
  secure = false,
  monospaced = false,
  icon,
  disabled = false,
  style,
  ...rest
}) {
  const [focus, setFocus] = React.useState(false);
  const isControlled = value !== undefined;
  const [internal, setInternal] = React.useState(defaultValue ?? "");
  const val = isControlled ? value : internal;
  const handle = e => {
    if (!isControlled) setInternal(e.target.value);
    onChange && onChange(e.target.value);
  };
  return /*#__PURE__*/React.createElement("div", {
    style: {
      position: "relative",
      display: "flex",
      alignItems: "center",
      gap: "var(--space-4)",
      height: "var(--control-h-lg)",
      padding: "0 11px",
      borderRadius: "var(--radius-md)",
      background: "rgba(255,255,255,0.045)",
      boxShadow: focus ? "inset 0 1px 2px rgba(0,0,0,0.22), var(--shadow-focus)" : "inset 0 1px 2px rgba(0,0,0,0.22)",
      border: `${focus ? "1.5px" : "0.75px"} solid ${focus ? "var(--border-focus)" : "rgba(255,255,255,0.13)"}`,
      opacity: disabled ? 0.55 : 1,
      transition: "border-color var(--motion-content) var(--ease-out-cubic), box-shadow var(--motion-content) var(--ease-out-cubic)",
      ...style
    }
  }, icon && /*#__PURE__*/React.createElement("i", {
    "data-lucide": icon,
    style: {
      width: "14px",
      height: "14px",
      color: "var(--text-tertiary)",
      flex: "0 0 auto"
    },
    "aria-hidden": "true"
  }), /*#__PURE__*/React.createElement("input", _extends({
    type: secure ? "password" : type,
    value: val,
    onChange: handle,
    placeholder: placeholder,
    disabled: disabled,
    onFocus: () => setFocus(true),
    onBlur: () => setFocus(false),
    style: {
      flex: 1,
      minWidth: 0,
      background: "none",
      border: "none",
      outline: "none",
      color: "var(--text-primary)",
      fontFamily: monospaced || secure ? "var(--font-mono)" : "var(--font-sans)",
      fontSize: monospaced || secure ? "12px" : "var(--text-body)",
      letterSpacing: secure ? "0.08em" : "normal"
    }
  }, rest)));
}
Object.assign(__ds_scope, { Field });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/forms/Field.jsx", error: String((e && e.message) || e) }); }

// components/forms/Segmented.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
/**
 * notchmeet Segmented — an inset obsidian trough with a convex glass thumb that springs between
 * options (a periwinkle breath along its lit top edge). The selected label brightens to ink.
 * Used for binary/ternary choices like UI language (中文 / 日本語).
 */
function Segmented({
  options,
  value,
  defaultValue,
  onChange,
  style,
  ...rest
}) {
  const opts = options.map(o => typeof o === "string" ? {
    value: o,
    label: o
  } : o);
  const isControlled = value !== undefined;
  const [internal, setInternal] = React.useState(defaultValue ?? opts[0]?.value);
  const current = isControlled ? value : internal;
  const idx = Math.max(0, opts.findIndex(o => o.value === current));
  const select = v => {
    if (!isControlled) setInternal(v);
    onChange && onChange(v);
  };
  return /*#__PURE__*/React.createElement("div", _extends({
    role: "radiogroup",
    style: {
      position: "relative",
      display: "grid",
      gridTemplateColumns: `repeat(${opts.length}, 1fr)`,
      height: "var(--control-h-md)",
      padding: "2px",
      borderRadius: "var(--radius-lg)",
      background: "rgba(255,255,255,0.05)",
      boxShadow: "inset 0 1px 3px rgba(0,0,0,0.28)",
      border: "0.75px solid rgba(255,255,255,0.10)",
      ...style
    }
  }, rest), /*#__PURE__*/React.createElement("span", {
    "aria-hidden": "true",
    style: {
      position: "absolute",
      top: "3px",
      bottom: "3px",
      left: `calc(2px + ${idx} * ((100% - 4px) / ${opts.length}))`,
      width: `calc((100% - 4px) / ${opts.length} - 3px)`,
      marginLeft: "1.5px",
      borderRadius: "var(--radius-sm)",
      background: "linear-gradient(to bottom, rgba(255,255,255,0.16), rgba(255,255,255,0.04))",
      boxShadow: "0 1.5px 5px rgba(0,0,0,0.45), inset 0 0.5px 0 rgba(163,190,255,0.18)",
      border: "0.75px solid rgba(255,255,255,0.20)",
      transition: "left var(--motion-control) var(--ease-spring-snappy)"
    }
  }), opts.map(o => {
    const active = o.value === current;
    return /*#__PURE__*/React.createElement("button", {
      key: o.value,
      type: "button",
      role: "radio",
      "aria-checked": active,
      onClick: () => select(o.value),
      style: {
        position: "relative",
        zIndex: 1,
        background: "none",
        border: "none",
        cursor: "pointer",
        fontFamily: "var(--font-sans)",
        fontSize: "var(--text-control)",
        fontWeight: active ? "var(--weight-semibold)" : "var(--weight-medium)",
        color: active ? "var(--text-primary)" : "var(--text-secondary)",
        transition: "color var(--motion-content) var(--ease-out-cubic)",
        padding: "0 var(--space-4)",
        whiteSpace: "nowrap"
      }
    }, o.label);
  }));
}
Object.assign(__ds_scope, { Segmented });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/forms/Segmented.jsx", error: String((e && e.message) || e) }); }

// components/forms/Select.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
/**
 * notchmeet Select — a glass field that opens an obsidian menu (the app's popup → NSMenu).
 * Hairline-glass at rest, dither overlay, chevron.up.chevron.down affordance; the open menu is
 * a dark floating card with a periwinkle check on the current item.
 */
function Select({
  items,
  value,
  defaultValue,
  onChange,
  placeholder = "選択…",
  style,
  ...rest
}) {
  const opts = items.map(o => typeof o === "string" ? {
    value: o,
    label: o
  } : o);
  const isControlled = value !== undefined;
  const [internal, setInternal] = React.useState(defaultValue);
  const current = isControlled ? value : internal;
  const [open, setOpen] = React.useState(false);
  const [hover, setHover] = React.useState(false);
  const ref = React.useRef(null);
  React.useEffect(() => {
    const onDoc = e => {
      if (ref.current && !ref.current.contains(e.target)) setOpen(false);
    };
    document.addEventListener("mousedown", onDoc);
    return () => document.removeEventListener("mousedown", onDoc);
  }, []);
  const currentLabel = opts.find(o => o.value === current)?.label ?? placeholder;
  const pick = v => {
    if (!isControlled) setInternal(v);
    onChange && onChange(v);
    setOpen(false);
  };
  return /*#__PURE__*/React.createElement("div", _extends({
    ref: ref,
    style: {
      position: "relative",
      display: "inline-block",
      minWidth: "220px",
      ...style
    }
  }, rest), /*#__PURE__*/React.createElement("button", {
    type: "button",
    onClick: () => setOpen(o => !o),
    onMouseEnter: () => setHover(true),
    onMouseLeave: () => setHover(false),
    style: {
      position: "relative",
      width: "100%",
      height: "32px",
      display: "flex",
      alignItems: "center",
      justifyContent: "space-between",
      gap: "var(--space-4)",
      padding: "0 11px",
      borderRadius: "var(--radius-md)",
      background: hover ? "rgba(255,255,255,0.075)" : "rgba(255,255,255,0.05)",
      border: `0.75px solid ${hover ? "rgba(255,255,255,0.18)" : "rgba(255,255,255,0.12)"}`,
      cursor: "pointer",
      fontFamily: "var(--font-sans)",
      fontSize: "var(--text-body)",
      color: current ? "var(--text-primary)" : "var(--text-tertiary)",
      transition: "var(--transition-control)"
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      overflow: "hidden",
      textOverflow: "ellipsis",
      whiteSpace: "nowrap"
    }
  }, currentLabel), /*#__PURE__*/React.createElement("i", {
    "data-lucide": "chevrons-up-down",
    style: {
      width: "13px",
      height: "13px",
      color: "var(--text-secondary)",
      flex: "0 0 auto"
    },
    "aria-hidden": "true"
  })), open && /*#__PURE__*/React.createElement("div", {
    role: "listbox",
    style: {
      position: "absolute",
      top: "calc(100% + 6px)",
      left: 0,
      right: 0,
      zIndex: 50,
      padding: "var(--space-2)",
      borderRadius: "var(--radius-lg)",
      background: "rgba(14,16,24,0.96)",
      border: "0.75px solid rgba(255,255,255,0.12)",
      boxShadow: "var(--shadow-card)",
      backdropFilter: "blur(20px)",
      WebkitBackdropFilter: "blur(20px)"
    }
  }, opts.map(o => {
    const active = o.value === current;
    return /*#__PURE__*/React.createElement("button", {
      key: o.value,
      type: "button",
      role: "option",
      "aria-selected": active,
      onClick: () => pick(o.value),
      style: {
        width: "100%",
        display: "flex",
        alignItems: "center",
        gap: "var(--space-4)",
        padding: "7px 9px",
        borderRadius: "var(--radius-xs)",
        background: "none",
        border: "none",
        cursor: "pointer",
        textAlign: "left",
        fontFamily: "var(--font-sans)",
        fontSize: "var(--text-body)",
        color: active ? "var(--text-primary)" : "var(--text-secondary)"
      },
      onMouseEnter: e => e.currentTarget.style.background = "rgba(255,255,255,0.06)",
      onMouseLeave: e => e.currentTarget.style.background = "none"
    }, /*#__PURE__*/React.createElement("i", {
      "data-lucide": "check",
      style: {
        width: "13px",
        height: "13px",
        flex: "0 0 auto",
        color: "var(--accent)",
        opacity: active ? 1 : 0
      },
      "aria-hidden": "true"
    }), /*#__PURE__*/React.createElement("span", {
      style: {
        overflow: "hidden",
        textOverflow: "ellipsis",
        whiteSpace: "nowrap"
      }
    }, o.label));
  })));
}
Object.assign(__ds_scope, { Select });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/forms/Select.jsx", error: String((e && e.message) || e) }); }

// components/forms/Toggle.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
/**
 * notchmeet Toggle — a hand-built switch: an obsidian trough that cross-fades to a periwinkle
 * fill (with an inner top sheen) when on, and a convex knob that springs across. No stock control.
 */
function Toggle({
  checked,
  defaultChecked = false,
  onChange,
  disabled = false,
  style,
  ...rest
}) {
  const isControlled = checked !== undefined;
  const [internal, setInternal] = React.useState(defaultChecked);
  const on = isControlled ? checked : internal;
  const [hover, setHover] = React.useState(false);
  const toggle = () => {
    if (disabled) return;
    const next = !on;
    if (!isControlled) setInternal(next);
    onChange && onChange(next);
  };
  return /*#__PURE__*/React.createElement("button", _extends({
    type: "button",
    role: "switch",
    "aria-checked": on,
    disabled: disabled,
    onClick: toggle,
    onMouseEnter: () => setHover(true),
    onMouseLeave: () => setHover(false),
    style: {
      position: "relative",
      width: "38px",
      height: "22px",
      flex: "0 0 auto",
      borderRadius: "var(--radius-pill)",
      border: `0.75px solid ${on ? "rgba(88,120,232,0.7)" : "rgba(255,255,255,0.12)"}`,
      backgroundColor: on ? "transparent" : "rgba(255,255,255,0.08)",
      backgroundImage: on ? "var(--grad-key)" : "none",
      cursor: disabled ? "default" : "pointer",
      opacity: disabled ? 0.55 : 1,
      padding: 0,
      transition: "background-color var(--motion-content) var(--ease-out-cubic), border-color var(--motion-content) var(--ease-out-cubic)",
      ...style
    }
  }, rest), on && /*#__PURE__*/React.createElement("span", {
    "aria-hidden": "true",
    style: {
      position: "absolute",
      inset: 0,
      borderRadius: "inherit",
      backgroundImage: "linear-gradient(to bottom, rgba(255,255,255,0.22), transparent 60%)",
      mixBlendMode: "plus-lighter",
      pointerEvents: "none"
    }
  }), /*#__PURE__*/React.createElement("span", {
    "aria-hidden": "true",
    style: {
      position: "absolute",
      top: "2px",
      left: on ? "18px" : "2px",
      width: "18px",
      height: "18px",
      borderRadius: "var(--radius-pill)",
      background: hover ? "#ffffff" : "#f7f7f7",
      backgroundImage: "linear-gradient(to bottom, rgba(255,255,255,0.2), transparent 50%)",
      boxShadow: "0 1px 3px rgba(0,0,0,0.5)",
      transition: "left var(--motion-content) var(--ease-spring-snappy), background var(--motion-control) var(--ease-out-cubic)"
    }
  }));
}
Object.assign(__ds_scope, { Toggle });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/forms/Toggle.jsx", error: String((e && e.message) || e) }); }

// components/notch/ProgressRail.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
/**
 * notchmeet ProgressRail — the onboarding step indicator. Filled periwinkle segments behind you,
 * an elongated lit pill for the step you're on, hairline dots ahead. Width + fill animate as a
 * unit so the rail flows with the step.
 */
function ProgressRail({
  step = 0,
  total = 5,
  style,
  ...rest
}) {
  return /*#__PURE__*/React.createElement("div", _extends({
    role: "progressbar",
    "aria-valuenow": step + 1,
    "aria-valuemin": 1,
    "aria-valuemax": total,
    style: {
      display: "flex",
      alignItems: "center",
      gap: "var(--space-3)",
      ...style
    }
  }, rest), Array.from({
    length: total
  }).map((_, i) => {
    const current = i === step;
    const done = i <= step;
    return /*#__PURE__*/React.createElement("span", {
      key: i,
      style: {
        height: "6px",
        width: current ? "26px" : "7px",
        borderRadius: "var(--radius-pill)",
        background: done ? "var(--grad-key)" : "rgba(255,255,255,0.14)",
        boxShadow: current ? "0 0 6px rgba(125,162,255,0.55)" : "none",
        transition: "width var(--motion-morph) var(--ease-spring), background var(--motion-content) var(--ease-out-cubic)"
      }
    });
  }));
}
Object.assign(__ds_scope, { ProgressRail });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/notch/ProgressRail.jsx", error: String((e && e.message) || e) }); }

// components/notch/StatusJewel.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
/**
 * notchmeet StatusJewel — the bespoke status instrument shared by the collapsed bar and the
 * expanded notch header. The recording state is always an outer red ring; the inner mark conveys
 * pipeline state without relying on colour alone. States crossfade so the notch never blinks.
 *
 *   ready      → a dim, slow breathing dot
 *   listening  → a red breathing dot (faster, larger)
 *   thinking   → a sweeping periwinkle arc spinner
 *   streaming  → a 3-bar periwinkle equalizer
 *   presenting → a periwinkle checkmark
 *   error      → an orange exclamation
 */
function StatusJewel({
  status = "ready",
  recording = false,
  size = 16,
  style,
  ...rest
}) {
  const px = n => `${n / 16 * size}px`;
  const accent = "var(--nm-accent-notch)";
  return /*#__PURE__*/React.createElement("span", _extends({
    style: {
      position: "relative",
      display: "inline-flex",
      width: `${size}px`,
      height: `${size}px`,
      alignItems: "center",
      justifyContent: "center",
      flex: "0 0 auto",
      ...style
    },
    role: "img",
    "aria-label": `status: ${status}${recording ? ", recording" : ""}`
  }, rest), /*#__PURE__*/React.createElement("style", null, `
        @keyframes nm-breathe { 0%,100%{transform:scale(0.86);opacity:0.74} 50%{transform:scale(1.14);opacity:1} }
        @keyframes nm-breathe-live { 0%,100%{transform:scale(0.78);opacity:0.7} 50%{transform:scale(1.3);opacity:1} }
        @keyframes nm-spin { to { transform: rotate(360deg); } }
        @keyframes nm-eq1 { 0%,100%{height:${px(3.5)}} 50%{height:${px(10.5)}} }
        @keyframes nm-eq2 { 0%,100%{height:${px(9)}} 50%{height:${px(4)}} }
        @keyframes nm-eq3 { 0%,100%{height:${px(5)}} 50%{height:${px(10)}} }
        @media (prefers-reduced-motion: reduce){
          .nm-anim{animation:none!important}
        }
      `), recording && /*#__PURE__*/React.createElement("span", {
    "aria-hidden": "true",
    style: {
      position: "absolute",
      width: px(14),
      height: px(14),
      borderRadius: "50%",
      border: `${px(1.2)} solid var(--nm-recording)`,
      boxShadow: "0 0 5px rgba(255,69,58,0.55)"
    }
  }), status === "ready" && /*#__PURE__*/React.createElement("span", {
    className: "nm-anim",
    "aria-hidden": "true",
    style: {
      width: px(4.5),
      height: px(4.5),
      borderRadius: "50%",
      background: "var(--text-tertiary)",
      animation: "nm-breathe 2.85s ease-in-out infinite"
    }
  }), status === "listening" && /*#__PURE__*/React.createElement("span", {
    className: "nm-anim",
    "aria-hidden": "true",
    style: {
      width: px(6),
      height: px(6),
      borderRadius: "50%",
      background: "var(--nm-recording)",
      animation: "nm-breathe-live 1.33s ease-in-out infinite"
    }
  }), status === "thinking" && /*#__PURE__*/React.createElement("span", {
    "aria-hidden": "true",
    style: {
      position: "relative",
      width: px(10.5),
      height: px(10.5)
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      position: "absolute",
      inset: 0,
      borderRadius: "50%",
      border: `${px(1.6)} solid ${accent}`,
      opacity: 0.16
    }
  }), /*#__PURE__*/React.createElement("span", {
    className: "nm-anim",
    style: {
      position: "absolute",
      inset: 0,
      borderRadius: "50%",
      border: `${px(1.6)} solid transparent`,
      borderTopColor: accent,
      animation: "nm-spin 1.1s linear infinite"
    }
  })), status === "streaming" && /*#__PURE__*/React.createElement("span", {
    "aria-hidden": "true",
    style: {
      display: "flex",
      alignItems: "center",
      gap: px(1.6),
      height: px(11)
    }
  }, [{
    a: "nm-eq1",
    d: "0s"
  }, {
    a: "nm-eq2",
    d: "0.11s"
  }, {
    a: "nm-eq3",
    d: "0.22s"
  }].map((b, i) => /*#__PURE__*/React.createElement("span", {
    key: i,
    className: "nm-anim",
    style: {
      width: px(2),
      borderRadius: px(1),
      background: accent,
      animation: `${b.a} 0.66s ease-in-out infinite`,
      animationDelay: b.d
    }
  }))), status === "presenting" && /*#__PURE__*/React.createElement("i", {
    "data-lucide": "check",
    style: {
      width: px(11),
      height: px(11),
      color: accent,
      strokeWidth: 3.2
    },
    "aria-hidden": "true"
  }), status === "error" && /*#__PURE__*/React.createElement("i", {
    "data-lucide": "alert-triangle",
    style: {
      width: px(11),
      height: px(11),
      color: "var(--nm-warning)",
      strokeWidth: 2.6
    },
    "aria-hidden": "true"
  }));
}
Object.assign(__ds_scope, { StatusJewel });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/notch/StatusJewel.jsx", error: String((e && e.message) || e) }); }

// ui_kits/notch/NotchPanel.jsx
try { (() => {
/* notchmeet — The Notch surface.
 * The machined-obsidian slab that lives in the MacBook notch. Collapsed it fuses with the
 * hardware cutout (pure black, top corners tight); expanded it grows downward into an obsidian
 * card carrying the recognized question + the live Japanese answer, a status jewel, and controls.
 * Composes StatusJewel + Button from the design-system bundle.
 */
const {
  StatusJewel
} = window.NotchmeetDesignSystem_fc3301;

// A quiet hairline-glass control button (record / settings), matching NotchControlButton.
function NotchControl({
  icon,
  label,
  tint = "var(--text-secondary)",
  onClick
}) {
  const [hover, setHover] = React.useState(false);
  const [press, setPress] = React.useState(false);
  return /*#__PURE__*/React.createElement("button", {
    type: "button",
    title: label,
    "aria-label": label,
    onClick: onClick,
    onMouseEnter: () => setHover(true),
    onMouseLeave: () => {
      setHover(false);
      setPress(false);
    },
    onMouseDown: () => setPress(true),
    onMouseUp: () => setPress(false),
    style: {
      width: 28,
      height: 24,
      display: "inline-flex",
      alignItems: "center",
      justifyContent: "center",
      borderRadius: "var(--radius-sm)",
      background: hover ? "rgba(255,255,255,0.10)" : "transparent",
      border: hover ? "0.75px solid rgba(255,255,255,0.12)" : "0.75px solid transparent",
      color: tint,
      cursor: "pointer",
      transform: press ? "scale(var(--press-scale-tight))" : "scale(1)",
      opacity: press ? 0.72 : hover ? 1 : 0.82,
      transition: "var(--transition-control)"
    }
  }, /*#__PURE__*/React.createElement("i", {
    "data-lucide": icon,
    style: {
      width: 14,
      height: 14
    },
    "aria-hidden": "true"
  }));
}

/**
 * The notch slab. `expanded` morphs it open; `status`/`recording` drive the jewel; `heard` is the
 * recognized question; `answer` is the streamed Japanese answer.
 */
function NotchPanel({
  expanded,
  status,
  recording,
  heard,
  answer,
  statusText,
  onToggleRecord,
  onSettings
}) {
  return /*#__PURE__*/React.createElement("div", {
    style: {
      position: "relative",
      width: expanded ? 520 : 220,
      background: "#000",
      borderRadius: expanded ? "8px 8px 16px 16px" : "0 0 11px 11px",
      boxShadow: expanded ? "var(--shadow-notch)" : "none",
      // expanded lower face catches a cool sheen along its edge
      backgroundImage: expanded ? "radial-gradient(120% 90% at 50% 120%, rgba(204,219,255,0.06), transparent 60%)" : "none",
      border: expanded ? "0.5px solid rgba(255,255,255,0.07)" : "none",
      borderTop: "none",
      overflow: "hidden",
      transition: "width var(--motion-morph) var(--ease-settle), border-radius var(--motion-morph) var(--ease-settle)"
    }
  }, /*#__PURE__*/React.createElement("span", {
    "aria-hidden": "true",
    style: {
      position: "absolute",
      inset: 0,
      pointerEvents: "none",
      backgroundImage: "var(--dither-tile)",
      mixBlendMode: "plus-lighter",
      opacity: 0.025
    }
  }), /*#__PURE__*/React.createElement("span", {
    "aria-hidden": "true",
    style: {
      position: "absolute",
      left: 0,
      right: 0,
      top: 0,
      height: 14,
      pointerEvents: "none",
      background: "linear-gradient(to bottom, rgba(0,0,0,0.55), transparent)"
    }
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      alignItems: "center",
      gap: 10,
      height: 32,
      padding: "0 12px"
    }
  }, /*#__PURE__*/React.createElement(StatusJewel, {
    status: status,
    recording: recording,
    size: 16
  }), /*#__PURE__*/React.createElement("span", {
    style: {
      flex: 1,
      fontSize: 11.5,
      fontWeight: 600,
      letterSpacing: 0.2,
      color: status === "presenting" ? "var(--nm-accent-notch)" : "var(--text-secondary)",
      whiteSpace: "nowrap",
      overflow: "hidden",
      textOverflow: "ellipsis"
    }
  }, statusText), expanded && /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      gap: 2
    }
  }, /*#__PURE__*/React.createElement(NotchControl, {
    icon: recording ? "square" : "circle",
    tint: recording ? "var(--nm-recording)" : "var(--text-secondary)",
    label: recording ? "録音を停止" : "録音を開始",
    onClick: onToggleRecord
  }), /*#__PURE__*/React.createElement(NotchControl, {
    icon: "settings",
    label: "\u8A2D\u5B9A",
    onClick: onSettings
  }))), /*#__PURE__*/React.createElement("div", {
    style: {
      maxHeight: expanded ? 240 : 0,
      opacity: expanded ? 1 : 0,
      transition: "max-height var(--motion-morph) var(--ease-settle), opacity var(--motion-content) var(--ease-out-cubic)"
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      padding: "2px 16px 16px"
    }
  }, heard && /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      gap: 7,
      alignItems: "baseline",
      fontSize: 12,
      color: "var(--text-tertiary)",
      marginBottom: 9
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      color: "var(--nm-accent-notch)",
      fontWeight: 600,
      flex: "0 0 auto"
    }
  }, "\u805E\u304D\u53D6\u308A"), /*#__PURE__*/React.createElement("span", {
    style: {
      overflow: "hidden",
      textOverflow: "ellipsis",
      whiteSpace: "nowrap"
    }
  }, heard)), /*#__PURE__*/React.createElement("div", {
    style: {
      fontSize: answer ? 15 : 13,
      lineHeight: 1.5,
      color: answer ? "var(--nm-ink-96)" : "var(--text-secondary)",
      minHeight: 46
    }
  }, answer || "待機中 · ●をタップ／⌘⇧Pで録音開始", status === "streaming" && /*#__PURE__*/React.createElement("span", {
    className: "nm-caret",
    style: {
      display: "inline-block",
      width: 2,
      height: 16,
      marginLeft: 2,
      verticalAlign: "-2px",
      background: "var(--nm-accent-notch)"
    }
  })))));
}
window.NotchPanel = NotchPanel;
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/notch/NotchPanel.jsx", error: String((e && e.message) || e) }); }

// ui_kits/onboarding/Onboarding.jsx
try { (() => {
/* notchmeet — Onboarding window.
 * A five-step welcome over the living aurora. A breathing app-icon hero with a single ring of
 * light + grounded contact shadow (never a blurry halo); a kicker; the progress rail; and the
 * convex accent buttons. Composes Kicker, ProgressRail, Button from the design-system bundle.
 */
const {
  Kicker,
  ProgressRail,
  Button
} = window.NotchmeetDesignSystem_fc3301;
function HeroIcon({
  size = 104,
  done = false
}) {
  return /*#__PURE__*/React.createElement("div", {
    style: {
      position: "relative",
      width: size * 1.2,
      height: size * 1.3,
      display: "flex",
      alignItems: "center",
      justifyContent: "center"
    }
  }, /*#__PURE__*/React.createElement("span", {
    "aria-hidden": "true",
    style: {
      position: "absolute",
      bottom: size * 0.05,
      width: size * 0.82,
      height: size * 0.16,
      background: "rgba(0,0,0,0.5)",
      filter: "blur(11px)",
      borderRadius: "50%"
    }
  }), /*#__PURE__*/React.createElement("div", {
    className: "nm-hero-float",
    style: {
      position: "relative"
    }
  }, /*#__PURE__*/React.createElement("img", {
    src: "../../assets/notchmeet-icon-256.png",
    width: size,
    height: size,
    alt: "notchmeet",
    style: {
      display: "block",
      borderRadius: size * 0.235,
      boxShadow: "0 12px 26px rgba(125,162,255,0.28), 0 3px 6px rgba(0,0,0,0.4)"
    }
  }), /*#__PURE__*/React.createElement("span", {
    "aria-hidden": "true",
    style: {
      position: "absolute",
      inset: 0,
      borderRadius: size * 0.235,
      border: "1px solid transparent",
      borderImage: "var(--grad-edge-glass) 1"
    }
  }), done && /*#__PURE__*/React.createElement("span", {
    "aria-hidden": "true",
    style: {
      position: "absolute",
      right: -size * 0.06,
      bottom: -size * 0.06,
      width: size * 0.36,
      height: size * 0.36,
      borderRadius: "50%",
      background: "var(--grad-key)",
      border: `3px solid var(--nm-bg)`,
      display: "flex",
      alignItems: "center",
      justifyContent: "center",
      boxShadow: "0 3px 8px rgba(88,120,232,0.5)"
    }
  }, /*#__PURE__*/React.createElement("i", {
    "data-lucide": "check",
    style: {
      width: size * 0.17,
      height: size * 0.17,
      color: "#fff",
      strokeWidth: 3.5
    }
  }))));
}
const STEPS = [{
  kicker: "ようこそ",
  title: "そのまま、読むだけ。",
  body: "notchmeet は、オンライン面接の質問をリアルタイムで聞き取り、そのまま読める日本語の回答を MacBook のノッチに表示します。",
  hero: "welcome",
  cta: "はじめる"
}, {
  kicker: "Step 01 · しくみ",
  title: "面接官の声だけを聞き取る",
  body: "通話アプリの音声のみを取得し（マイク・カメラ・画面は不使用）、Deepgram で文字起こし。約3秒で、ノッチに回答が現れます。",
  hero: "listen",
  cta: "次へ"
}, {
  kicker: "Step 02 · プライバシー",
  title: "データの送信先を、正直に。",
  body: "認識された質問は、あなたの履歴書メモと面接原稿とともに AI に送信され回答を生成します。API キーのみ端末内に保存され、いつでも送信をオフにできます。",
  hero: "privacy",
  cta: "次へ"
}, {
  kicker: "Step 03 · 準備",
  title: "原稿を用意しておく",
  body: "用意した回答を読み込むか貼り付けてください。一致した質問では原稿をそのまま提示し、外れた場合は日本語回答の参考にします。",
  hero: "prep",
  cta: "次へ"
}, {
  kicker: "準備完了",
  title: "面接の準備ができました",
  body: "通話アプリを開いて録音を開始すれば、ノッチが答えを表示します。落ち着いて、自分の言葉で。",
  hero: "done",
  cta: "notchmeet を始める"
}];
function HeroVisual({
  kind
}) {
  if (kind === "welcome") return /*#__PURE__*/React.createElement(HeroIcon, null);
  if (kind === "done") return /*#__PURE__*/React.createElement(HeroIcon, {
    done: true
  });
  const icon = {
    listen: "ear",
    privacy: "shield-check",
    prep: "file-text"
  }[kind] || "sparkles";
  return /*#__PURE__*/React.createElement("div", {
    style: {
      width: 96,
      height: 96,
      borderRadius: "var(--radius-card)",
      display: "flex",
      alignItems: "center",
      justifyContent: "center",
      background: "rgba(125,162,255,0.10)",
      border: "0.75px solid rgba(125,162,255,0.28)",
      boxShadow: "inset 0 1px 0 rgba(255,255,255,0.08)"
    }
  }, /*#__PURE__*/React.createElement("i", {
    "data-lucide": icon,
    style: {
      width: 38,
      height: 38,
      color: "var(--nm-accent)"
    }
  }));
}
function OnboardingWindow() {
  const [step, setStep] = React.useState(0);
  const s = STEPS[step];
  const last = step === STEPS.length - 1;
  React.useEffect(() => {
    window.lucide && window.lucide.createIcons();
  });
  return /*#__PURE__*/React.createElement("div", {
    className: "ob-window nm-aurora nm-dither"
  }, /*#__PURE__*/React.createElement("div", {
    className: "ob-titlebar"
  }, /*#__PURE__*/React.createElement("span", {
    className: "dot",
    style: {
      background: "#FF5F57"
    }
  }), /*#__PURE__*/React.createElement("span", {
    className: "dot",
    style: {
      background: "#FEBC2E"
    }
  }), /*#__PURE__*/React.createElement("span", {
    className: "dot",
    style: {
      background: "#28C840"
    }
  })), /*#__PURE__*/React.createElement("div", {
    className: "ob-body",
    key: step
  }, /*#__PURE__*/React.createElement("div", {
    className: "ob-hero"
  }, /*#__PURE__*/React.createElement(HeroVisual, {
    kind: s.hero
  })), /*#__PURE__*/React.createElement(Kicker, null, s.kicker), /*#__PURE__*/React.createElement("h1", {
    className: "ob-title"
  }, s.title), /*#__PURE__*/React.createElement("p", {
    className: "ob-text"
  }, s.body)), /*#__PURE__*/React.createElement("div", {
    className: "ob-foot"
  }, /*#__PURE__*/React.createElement("div", {
    className: "ob-foot-left"
  }, step > 0 && !last && /*#__PURE__*/React.createElement(Button, {
    variant: "plain",
    icon: "chevron-left",
    onClick: () => setStep(n => n - 1)
  }, "\u623B\u308B")), /*#__PURE__*/React.createElement(ProgressRail, {
    step: step,
    total: STEPS.length
  }), /*#__PURE__*/React.createElement("div", {
    className: "ob-foot-right"
  }, !last && step < STEPS.length - 2 && step > 0 && /*#__PURE__*/React.createElement(Button, {
    variant: "plain",
    onClick: () => setStep(STEPS.length - 1)
  }, "\u30B9\u30AD\u30C3\u30D7"), /*#__PURE__*/React.createElement(Button, {
    variant: "primary",
    size: last || step === 0 ? "lg" : "md",
    iconRight: last ? "arrow-right" : undefined,
    onClick: () => setStep(n => last ? 0 : n + 1)
  }, s.cta))));
}
window.OnboardingWindow = OnboardingWindow;
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/onboarding/Onboarding.jsx", error: String((e && e.message) || e) }); }

// ui_kits/settings/Settings.jsx
try { (() => {
/* notchmeet — Settings window.
 * Six sections over the living aurora, with a full-height obsidian sidebar and a liquid selection
 * pill that springs between items (leading periwinkle tick on the active one). Composes the full
 * forms kit — Segmented, Toggle, Field, Select — plus Button, Badge, Card from the bundle.
 */
const {
  Segmented,
  Toggle,
  Field,
  Select,
  Button,
  Badge,
  Card
} = window.NotchmeetDesignSystem_fc3301;
const SECTIONS = [{
  id: "general",
  label: "一般",
  icon: "settings-2"
}, {
  id: "scripts",
  label: "面接原稿",
  icon: "file-text"
}, {
  id: "keys",
  label: "API キー",
  icon: "key-round"
}, {
  id: "answer",
  label: "回答エンジン",
  icon: "sparkles"
}, {
  id: "privacy",
  label: "プライバシー",
  icon: "shield-check"
}, {
  id: "about",
  label: "概要",
  icon: "info"
}];

// A settings row: title + help on the left, a control on the right.
function Row({
  title,
  help,
  children,
  top
}) {
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      alignItems: "center",
      justifyContent: "space-between",
      gap: 24,
      padding: "16px 0",
      borderTop: top ? "0.75px solid var(--nm-rule)" : "none"
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      maxWidth: 380
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      fontSize: 13.5,
      color: "var(--text-primary)"
    }
  }, title), help && /*#__PURE__*/React.createElement("div", {
    style: {
      fontSize: 12,
      color: "var(--text-tertiary)",
      marginTop: 3,
      lineHeight: 1.45
    }
  }, help)), /*#__PURE__*/React.createElement("div", {
    style: {
      flex: "0 0 auto"
    }
  }, children));
}
function SectionHeader({
  kicker,
  title
}) {
  return /*#__PURE__*/React.createElement("div", {
    style: {
      marginBottom: 8
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      fontSize: 11,
      fontWeight: 600,
      letterSpacing: "1.5px",
      textTransform: "uppercase",
      color: "var(--nm-accent)",
      marginBottom: 8
    }
  }, kicker), /*#__PURE__*/React.createElement("h2", {
    style: {
      margin: 0,
      fontSize: 19,
      fontWeight: 600,
      color: "var(--text-primary)"
    }
  }, title));
}

// ---- Section bodies ----

function GeneralSection() {
  return /*#__PURE__*/React.createElement(React.Fragment, null, /*#__PURE__*/React.createElement(SectionHeader, {
    kicker: "General",
    title: "\u4E00\u822C"
  }), /*#__PURE__*/React.createElement(Row, {
    title: "\u8868\u793A\u8A00\u8A9E",
    help: "\u753B\u9762\u306E\u8A00\u8A9E\u3002\u9762\u63A5\u3068\u56DE\u7B54\u306F\u5E38\u306B\u65E5\u672C\u8A9E\u3067\u3059\u3002"
  }, /*#__PURE__*/React.createElement(Segmented, {
    options: ["中文", "日本語"],
    defaultValue: "\u65E5\u672C\u8A9E"
  })), /*#__PURE__*/React.createElement(Row, {
    top: true,
    title: "\u8A00\u8A9E\u306E\u6982\u8981",
    help: "\u753B\u9762\uFF1A\u65E5\u672C\u8A9E\u30FB\u9762\u63A5\u3068\u56DE\u7B54\uFF1A\u65E5\u672C\u8A9E"
  }, /*#__PURE__*/React.createElement(Badge, {
    tone: "accent"
  }, "\u65E5\u672C\u8A9E")), /*#__PURE__*/React.createElement(Row, {
    top: true,
    title: "\u306F\u3058\u3081\u306B\u30AC\u30A4\u30C9",
    help: "\u65B0\u898F\u30BB\u30C3\u30C8\u30A2\u30C3\u30D7\u306E\u624B\u9806\u3092\u3082\u3046\u4E00\u5EA6\u8868\u793A\u3057\u307E\u3059\u3002"
  }, /*#__PURE__*/React.createElement(Button, {
    variant: "secondary",
    icon: "rotate-ccw"
  }, "\u518D\u8868\u793A")));
}
function ScriptsSection() {
  const scripts = [{
    name: "総合職 ESベース",
    count: 18,
    date: "2026/06/22",
    active: true
  }, {
    name: "メガバンク向け",
    count: 12,
    date: "2026/06/20",
    active: false
  }, {
    name: "我的原稿",
    count: 7,
    date: "2026/06/14",
    active: false
  }];
  return /*#__PURE__*/React.createElement(React.Fragment, null, /*#__PURE__*/React.createElement(SectionHeader, {
    kicker: "Scripts",
    title: "\u9762\u63A5\u539F\u7A3F"
  }), /*#__PURE__*/React.createElement("p", {
    style: {
      fontSize: 12.5,
      color: "var(--text-secondary)",
      lineHeight: 1.5,
      margin: "0 0 14px",
      maxWidth: 460
    }
  }, "\u4E00\u81F4\u3057\u305F\u8CEA\u554F\u3067\u306F\u539F\u7A3F\u3092\u305D\u306E\u307E\u307E\u63D0\u793A\u3057\u3001\u5916\u308C\u305F\u5834\u5408\u306F\u65E5\u672C\u8A9E\u56DE\u7B54\u306E\u53C2\u8003\u306B\u3057\u307E\u3059\u3002"), /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      flexDirection: "column",
      gap: 8
    }
  }, scripts.map(s => /*#__PURE__*/React.createElement(ScriptRow, {
    key: s.name,
    s: s
  }))), /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      gap: 10,
      marginTop: 16
    }
  }, /*#__PURE__*/React.createElement(Button, {
    variant: "secondary",
    icon: "upload"
  }, "\u30D5\u30A1\u30A4\u30EB\u304B\u3089\u8AAD\u307F\u8FBC\u3080\u2026"), /*#__PURE__*/React.createElement(Button, {
    variant: "secondary",
    icon: "clipboard-paste"
  }, "\u8CBC\u308A\u4ED8\u3051\u3066\u65B0\u898F\u4F5C\u6210")));
}
function ScriptRow({
  s
}) {
  const [hover, setHover] = React.useState(false);
  return /*#__PURE__*/React.createElement("div", {
    onMouseEnter: () => setHover(true),
    onMouseLeave: () => setHover(false),
    style: {
      display: "flex",
      alignItems: "center",
      gap: 12,
      padding: "11px 14px",
      borderRadius: "var(--radius-md)",
      background: hover ? "var(--surface-card-hover)" : "var(--surface-card)",
      border: "0.75px solid var(--nm-rule)",
      transition: "background var(--motion-control) var(--ease-out-cubic)"
    }
  }, /*#__PURE__*/React.createElement("i", {
    "data-lucide": "file-text",
    style: {
      width: 16,
      height: 16,
      color: "var(--text-tertiary)"
    }
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      flex: 1,
      minWidth: 0
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      fontSize: 13,
      color: "var(--text-primary)",
      display: "flex",
      alignItems: "center",
      gap: 8
    }
  }, s.name, " ", s.active && /*#__PURE__*/React.createElement(Badge, {
    tone: "active"
  }, "\u4F7F\u7528\u4E2D")), /*#__PURE__*/React.createElement("div", {
    style: {
      fontSize: 11.5,
      color: "var(--text-tertiary)",
      marginTop: 2
    }
  }, s.count, " \u4EF6 \xB7 \u66F4\u65B0 ", s.date)), /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      gap: 4,
      opacity: hover ? 1 : 0,
      transition: "opacity var(--motion-control) var(--ease-out-cubic)"
    }
  }, !s.active && /*#__PURE__*/React.createElement(Button, {
    variant: "plain",
    size: "sm"
  }, "\u4ECA\u56DE\u4F7F\u7528\u3059\u308B"), /*#__PURE__*/React.createElement(Button, {
    variant: "plain",
    size: "sm",
    icon: "pencil"
  }), /*#__PURE__*/React.createElement(Button, {
    variant: "plain",
    size: "sm",
    icon: "trash-2"
  })));
}
function KeysSection() {
  const keys = [{
    name: "Deepgram キー",
    help: "音声認識",
    set: true
  }, {
    name: "Gemini キー",
    help: "回答 LLM",
    set: true
  }, {
    name: "Anthropic キー",
    help: "回答 LLM（Claude）",
    set: false
  }];
  return /*#__PURE__*/React.createElement(React.Fragment, null, /*#__PURE__*/React.createElement(SectionHeader, {
    kicker: "API Keys",
    title: "API \u30AD\u30FC"
  }), /*#__PURE__*/React.createElement("p", {
    style: {
      fontSize: 12.5,
      color: "var(--text-secondary)",
      margin: "0 0 16px",
      maxWidth: 460,
      lineHeight: 1.5
    }
  }, "\u30AD\u30FC\u3092\u5165\u529B\u3057\u3066\u304F\u3060\u3055\u3044\u3002\u7A7A\u6B04\u3067\u4FDD\u5B58\u3059\u308B\u3068\u524A\u9664\u3055\u308C\u3001Keychain \u306B\u4FDD\u7BA1\u3055\u308C\u307E\u3059\u3002"), /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      flexDirection: "column",
      gap: 18
    }
  }, keys.map(k => /*#__PURE__*/React.createElement("div", {
    key: k.name
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      alignItems: "center",
      gap: 8,
      marginBottom: 8
    }
  }, /*#__PURE__*/React.createElement("i", {
    "data-lucide": k.set ? "check-circle-2" : "circle",
    style: {
      width: 15,
      height: 15,
      color: k.set ? "var(--nm-accent)" : "var(--text-tertiary)"
    }
  }), /*#__PURE__*/React.createElement("span", {
    style: {
      fontSize: 13,
      color: "var(--text-primary)"
    }
  }, k.name), /*#__PURE__*/React.createElement("span", {
    style: {
      fontSize: 11.5,
      color: "var(--text-tertiary)"
    }
  }, "\xB7 ", k.help)), /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      gap: 8
    }
  }, /*#__PURE__*/React.createElement(Field, {
    secure: true,
    monospaced: true,
    placeholder: k.set ? "" : `${k.name}を入力`,
    icon: "key-round",
    style: {
      flex: 1
    }
  }), /*#__PURE__*/React.createElement(Button, {
    variant: "primary",
    icon: "check"
  }, "\u4FDD\u5B58"), k.set && /*#__PURE__*/React.createElement(Button, {
    variant: "plain"
  }, "\u30AF\u30EA\u30A2"))))));
}
function AnswerSection() {
  return /*#__PURE__*/React.createElement(React.Fragment, null, /*#__PURE__*/React.createElement(SectionHeader, {
    kicker: "Answer Engine",
    title: "\u56DE\u7B54\u30A8\u30F3\u30B8\u30F3"
  }), /*#__PURE__*/React.createElement(Row, {
    title: "\u56DE\u7B54 LLM",
    help: "\u8CEA\u554F\u304B\u3089\u56DE\u7B54\u3092\u751F\u6210\u3059\u308B\u30E2\u30C7\u30EB\u3002"
  }, /*#__PURE__*/React.createElement(Segmented, {
    options: [{
      value: "gemini",
      label: "Gemini"
    }, {
      value: "claude",
      label: "Claude"
    }],
    defaultValue: "gemini"
  })), /*#__PURE__*/React.createElement(Row, {
    top: true,
    title: "\u73FE\u5728\u306E\u56DE\u7B54\u30E2\u30C7\u30EB",
    help: "\u4F4E\u30EC\u30A4\u30C6\u30F3\u30B7\u512A\u5148\u3067\u9078\u5B9A\u3002"
  }, /*#__PURE__*/React.createElement("span", {
    className: "nm-mono",
    style: {
      fontSize: 12.5,
      color: "var(--text-secondary)"
    }
  }, "gemini-2.5-flash")), /*#__PURE__*/React.createElement(Row, {
    top: true,
    title: "\u97F3\u58F0\u8A8D\u8B58",
    help: "\u65E5\u672C\u8A9E\u30B9\u30C8\u30EA\u30FC\u30DF\u30F3\u30B0 STT\u3002"
  }, /*#__PURE__*/React.createElement("span", {
    className: "nm-mono",
    style: {
      fontSize: 12.5,
      color: "var(--text-secondary)"
    }
  }, "Deepgram \xB7 nova-3")));
}
function PrivacySection() {
  const [send, setSend] = React.useState(true);
  return /*#__PURE__*/React.createElement(React.Fragment, null, /*#__PURE__*/React.createElement(SectionHeader, {
    kicker: "Privacy",
    title: "\u30D7\u30E9\u30A4\u30D0\u30B7\u30FC\u3068\u30C7\u30FC\u30BF"
  }), /*#__PURE__*/React.createElement(Card, {
    elevated: false,
    padding: "15px 17px",
    style: {
      marginBottom: 8
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      gap: 10
    }
  }, /*#__PURE__*/React.createElement("i", {
    "data-lucide": "route",
    style: {
      width: 16,
      height: 16,
      color: "var(--nm-accent)",
      flex: "0 0 auto",
      marginTop: 2
    }
  }), /*#__PURE__*/React.createElement("p", {
    style: {
      margin: 0,
      fontSize: 12.5,
      color: "var(--text-secondary)",
      lineHeight: 1.55
    }
  }, "\u9332\u97F3\u4E2D\u3001\u9078\u629E\u3057\u305F\u901A\u8A71\u30A2\u30D7\u30EA\u306E\u97F3\u58F0\u306F\u30EA\u30A2\u30EB\u30BF\u30A4\u30E0\u3067 Deepgram \u306B\u9001\u4FE1\u3055\u308C\u6587\u5B57\u8D77\u3053\u3057\u3055\u308C\u307E\u3059\u3002 \u8A8D\u8B58\u3055\u308C\u305F\u8CEA\u554F\u306F\u9078\u629E\u3057\u305F AI \u306B\u9001\u4FE1\u3055\u308C\u56DE\u7B54\u3092\u751F\u6210\u3057\u307E\u3059\u3002API \u30AD\u30FC\u3068\u30ED\u30FC\u30AB\u30EB\u30D5\u30A1\u30A4\u30EB\u306F \u7AEF\u672B\u5185\u306B\u306E\u307F\u4FDD\u5B58\u3055\u308C\u3001\u30DE\u30A4\u30AF\u30FB\u30AB\u30E1\u30E9\u30FB\u753B\u9762\u306F\u4F7F\u7528\u3057\u307E\u305B\u3093\u3002"))), /*#__PURE__*/React.createElement(Row, {
    top: true,
    title: "\u5C65\u6B74\u66F8\u30E1\u30E2\u3068\u539F\u7A3F\u3092 AI \u306B\u9001\u4FE1",
    help: "\u30AA\u30D5\u306B\u3059\u308B\u3068\u56DE\u7B54\u306F\u4E00\u822C\u7684\u306B\u306A\u308A\u3001\u5C65\u6B74\u66F8\u3084\u539F\u7A3F\u3092 AI \u306B\u9001\u4FE1\u3057\u307E\u305B\u3093\u3002"
  }, /*#__PURE__*/React.createElement(Toggle, {
    checked: send,
    onChange: setSend
  })), /*#__PURE__*/React.createElement(Row, {
    top: true,
    title: "\u53D6\u5F97\u3059\u308B\u901A\u8A71\u30A2\u30D7\u30EA",
    help: "\u3053\u306E\u30A2\u30D7\u30EA\u306E\u97F3\u58F0\u306E\u307F\u3092\u53D6\u5F97\u3057\u307E\u3059\uFF08\u30B7\u30B9\u30C6\u30E0\u5168\u4F53\u3067\u306F\u3042\u308A\u307E\u305B\u3093\uFF09\u3002"
  }, /*#__PURE__*/React.createElement(Select, {
    items: [{
      value: "auto",
      label: "通話アプリを自動検出"
    }, {
      value: "zoom",
      label: "Zoom"
    }, {
      value: "chrome",
      label: "Google Chrome"
    }, {
      value: "teams",
      label: "Microsoft Teams"
    }],
    defaultValue: "auto"
  })), /*#__PURE__*/React.createElement(Row, {
    top: true,
    title: "\u30ED\u30FC\u30AB\u30EB\u30C7\u30FC\u30BF",
    help: "\u9762\u63A5\u539F\u7A3F\u30FB\u56DE\u7B54\u30D0\u30F3\u30AF\u30FB\u5C65\u6B74\u66F8\u30D5\u30A1\u30AF\u30C8\u30FB\u5168 API \u30AD\u30FC\u3092\u5B8C\u5168\u306B\u524A\u9664\u3057\u307E\u3059\u3002"
  }, /*#__PURE__*/React.createElement(Button, {
    variant: "destructive",
    icon: "trash-2"
  }, "\u524A\u9664\u2026")));
}
function AboutSection() {
  return /*#__PURE__*/React.createElement("div", {
    style: {
      textAlign: "center",
      paddingTop: 18
    }
  }, /*#__PURE__*/React.createElement("img", {
    src: "../../assets/notchmeet-icon-256.png",
    width: 92,
    height: 92,
    alt: "notchmeet",
    style: {
      borderRadius: 92 * 0.235,
      boxShadow: "var(--shadow-card)"
    }
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      fontSize: 22,
      fontWeight: 600,
      letterSpacing: "-0.01em",
      color: "var(--text-primary)",
      marginTop: 16
    }
  }, "notch", /*#__PURE__*/React.createElement("span", {
    style: {
      color: "var(--nm-accent)"
    }
  }, "meet")), /*#__PURE__*/React.createElement("div", {
    style: {
      fontSize: 13,
      color: "var(--text-secondary)",
      marginTop: 6
    }
  }, "\u65E5\u672C\u306E\u5C31\u6D3B\u5411\u3051\u30FB\u30EA\u30A2\u30EB\u30BF\u30A4\u30E0\u9762\u63A5\u30D7\u30ED\u30F3\u30D7\u30BF\u30FC"), /*#__PURE__*/React.createElement("div", {
    className: "nm-mono",
    style: {
      fontSize: 12,
      color: "var(--text-tertiary)",
      marginTop: 10
    }
  }, "\u30D0\u30FC\u30B8\u30E7\u30F3 1.0.0"), /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      gap: 10,
      justifyContent: "center",
      marginTop: 20
    }
  }, /*#__PURE__*/React.createElement(Button, {
    variant: "secondary",
    icon: "github"
  }, "\u30BD\u30FC\u30B9"), /*#__PURE__*/React.createElement(Button, {
    variant: "secondary",
    icon: "file-text"
  }, "\u30D7\u30E9\u30A4\u30D0\u30B7\u30FC\u30DD\u30EA\u30B7\u30FC")));
}
const BODIES = {
  general: GeneralSection,
  scripts: ScriptsSection,
  keys: KeysSection,
  answer: AnswerSection,
  privacy: PrivacySection,
  about: AboutSection
};
function SettingsWindow() {
  const [active, setActive] = React.useState("privacy");
  const idx = SECTIONS.findIndex(s => s.id === active);
  const Body = BODIES[active];
  React.useEffect(() => {
    window.lucide && window.lucide.createIcons();
  });
  return /*#__PURE__*/React.createElement("div", {
    className: "set-window"
  }, /*#__PURE__*/React.createElement("nav", {
    className: "set-sidebar"
  }, /*#__PURE__*/React.createElement("div", {
    className: "set-traffic"
  }, /*#__PURE__*/React.createElement("span", {
    className: "dot",
    style: {
      background: "#FF5F57"
    }
  }), /*#__PURE__*/React.createElement("span", {
    className: "dot",
    style: {
      background: "#FEBC2E"
    }
  }), /*#__PURE__*/React.createElement("span", {
    className: "dot",
    style: {
      background: "#28C840"
    }
  })), /*#__PURE__*/React.createElement("div", {
    className: "set-nav"
  }, /*#__PURE__*/React.createElement("div", {
    className: "set-pill",
    style: {
      transform: `translateY(${idx * 40}px)`
    },
    "aria-hidden": "true"
  }), SECTIONS.map(s => /*#__PURE__*/React.createElement("button", {
    key: s.id,
    className: "set-item" + (s.id === active ? " active" : ""),
    onClick: () => setActive(s.id)
  }, /*#__PURE__*/React.createElement("i", {
    "data-lucide": s.icon
  }), /*#__PURE__*/React.createElement("span", null, s.label))))), /*#__PURE__*/React.createElement("div", {
    className: "set-content nm-aurora nm-dither"
  }, /*#__PURE__*/React.createElement("div", {
    className: "set-scroll",
    key: active
  }, /*#__PURE__*/React.createElement(Body, null))));
}
window.SettingsWindow = SettingsWindow;
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/settings/Settings.jsx", error: String((e && e.message) || e) }); }

__ds_ns.Badge = __ds_scope.Badge;

__ds_ns.Button = __ds_scope.Button;

__ds_ns.Card = __ds_scope.Card;

__ds_ns.Kicker = __ds_scope.Kicker;

__ds_ns.Field = __ds_scope.Field;

__ds_ns.Segmented = __ds_scope.Segmented;

__ds_ns.Select = __ds_scope.Select;

__ds_ns.Toggle = __ds_scope.Toggle;

__ds_ns.ProgressRail = __ds_scope.ProgressRail;

__ds_ns.StatusJewel = __ds_scope.StatusJewel;

})();
