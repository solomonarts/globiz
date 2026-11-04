"use client";

import { useState, type InputHTMLAttributes } from "react";

type PasswordInputProps = Omit<InputHTMLAttributes<HTMLInputElement>, "type">;

export function PasswordInput({ className, style, ...props }: PasswordInputProps) {
  const [visible, setVisible] = useState(false);

  return (
    <span style={{ position: "relative", display: "block" }}>
      <input
        {...props}
        className={className}
        type={visible ? "text" : "password"}
        style={{ ...style, paddingRight: 74 }}
      />
      <button
        type="button"
        onClick={() => setVisible((current) => !current)}
        aria-label={visible ? "Hide password" : "Show password"}
        aria-pressed={visible}
        style={{
          position: "absolute",
          right: 10,
          top: "50%",
          transform: "translateY(-50%)",
          border: 0,
          padding: "4px 2px",
          background: "transparent",
          color: "#176b4d",
          cursor: "pointer",
          fontSize: 11,
          fontWeight: 700,
        }}
      >
        {visible ? "Hide" : "Show"}
      </button>
    </span>
  );
}
