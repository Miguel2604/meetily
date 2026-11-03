import React from "react";
import { Info as InfoIcon } from "lucide-react";
import { Dialog, DialogContent, DialogTitle, DialogTrigger } from "./ui/dialog";
import { VisuallyHidden } from "./ui/visually-hidden";
import { About } from "./About";

interface InfoProps {
    isCollapsed: boolean;
}

const Info = React.forwardRef<HTMLButtonElement, InfoProps>(({ isCollapsed }, ref) => {
  return (
    <Dialog aria-describedby={undefined}>
      <DialogTrigger asChild>
        <button
          ref={ref}
          className={isCollapsed
            ? "flex items-center justify-center w-10 h-10 rounded-md text-gray-600 hover:bg-black/[0.04] hover:text-gray-950 transition-colors"
            : "w-full flex items-center gap-2.5 h-8 px-2.5 rounded-md text-sm text-gray-700 hover:bg-black/[0.04] hover:text-gray-950 transition-colors"}
          aria-label="About Meety"
        >
          <InfoIcon className="w-4 h-4" strokeWidth={1.75} />
          {!isCollapsed && <span>About</span>}
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
});

Info.displayName = "About";

export default Info; 