import React from "react";
import { Dialog, DialogContent, DialogTitle, DialogTrigger } from "./ui/dialog";
import { VisuallyHidden } from "./ui/visually-hidden";
import { About } from "./About";
import { MeetyMark } from "./MeetyMark";

interface LogoProps {
  isCollapsed: boolean;
}

const Logo = React.forwardRef<HTMLButtonElement, LogoProps>(
  ({ isCollapsed }, ref) => {
    return (
      <Dialog aria-describedby={undefined}>
        <DialogTrigger asChild>
          <button
            ref={ref}
            type="button"
            className="flex items-center gap-2 rounded-md p-1 -m-1 hover:bg-black/[0.04] transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
            aria-label="About Meety"
          >
            <MeetyMark size={isCollapsed ? 28 : 22} />
            {!isCollapsed && <span className="text-[15px] font-semibold tracking-[-0.01em] text-gray-950">Meety</span>}
          </button>
        </DialogTrigger>
        <DialogContent>
          <VisuallyHidden>
            <DialogTitle>About Meety</DialogTitle>
          </VisuallyHidden>
          <About />
        </DialogContent>
      </Dialog>
    );
  },
);

Logo.displayName = "Logo";

export default Logo;
